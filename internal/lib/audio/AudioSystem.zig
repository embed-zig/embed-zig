//! audio.AudioSystem — type-erased audio-system surface.

const Mixer = @import("Mixer.zig");
const MicMod = @import("Mic.zig");
const SpeakerMod = @import("Speaker.zig");
const RingBufferMod = @import("mixer/RingBuffer.zig");
const glib = @import("glib");

pub const Format = Mixer.Format;
pub const Track = Mixer.Track;
pub const TrackCtrl = Mixer.TrackCtrl;
pub const TrackHandle = Mixer.TrackHandle;
pub const CreateTrackError = Mixer.CreateTrackError;

pub const Error = error{
    WouldBlock,
    Timeout,
    Overflow,
    InvalidState,
    Unsupported,
    Unexpected,
};

pub fn Builder(comptime lib: type) type {
    return struct {
        const Self = @This();

        mic: ?type = null,
        speaker: ?type = null,
        processor: ?type = null,

        pub fn init() Self {
            return .{};
        }

        pub fn configMic(self: *Self, comptime mic_count: usize, comptime samples_per_channel: usize) void {
            self.mic = MicMod.make(lib, mic_count, samples_per_channel);
        }

        pub fn configSpeaker(self: *Self, comptime samples_per_channel: usize) void {
            self.speaker = SpeakerMod.make(lib, samples_per_channel);
        }

        pub fn setProcessor(self: *Self, comptime process_fn: anytype) void {
            const MicType = self.mic orelse @compileError("AudioSystem.Builder.setProcessor requires configMic() first");
            _ = @as(*const fn (MicType.Frame, []i16) Error!usize, process_fn);
            self.processor = struct {
                pub const process = process_fn;
            };
        }

        pub fn build(comptime spec: Self) type {
            const MicType = spec.mic orelse @compileError("AudioSystem.Builder.build requires configMic()");
            const SpeakerType = spec.speaker orelse @compileError("AudioSystem.Builder.build requires configSpeaker()");
            const ProcessorType = spec.processor orelse @compileError("AudioSystem.Builder.build requires setProcessor()");
            const mic_count = MicType.frame_mic_count;
            const samples_per_channel = MicType.frame_samples_per_channel;
            const FrameType = MicType.Frame;

            comptime {
                _ = @as(*const fn (FrameType, []i16) Error!usize, ProcessorType.process);
            }

            return struct {
                const AudioSystem = @This();
                const DefaultMixer = Mixer.make(lib);
                const SampleRingBuffer = RingBufferMod.make(lib);
                const capture_buffer_capacity = samples_per_channel * 16;
                const ref_buffer_capacity = samples_per_channel * 16;

                pub const Mic = MicType;
                pub const Speaker = SpeakerType;
                pub const Frame = FrameType;
                pub const MicGains = MicType.Gains;
                pub const frame_mic_count: usize = mic_count;
                pub const frame_samples_per_channel: usize = samples_per_channel;

                allocator: lib.mem.Allocator,
                mic_impl: ?AudioSystem.Mic = null,
                speaker_impl: ?AudioSystem.Speaker = null,
                playback: ?Mixer = null,
                capture_rb: SampleRingBuffer,
                ref_rb: SampleRingBuffer,
                ref_write_scratch: []i16,
                state_mu: lib.Thread.Mutex = .{},
                running: bool = false,
                async_failed: bool = false,
                playback_config_locked: bool = false,
                read_thread: ?lib.Thread = null,
                write_thread: ?lib.Thread = null,

                pub fn init(allocator: lib.mem.Allocator) !AudioSystem {
                    const capture_rb = try SampleRingBuffer.init(allocator, capture_buffer_capacity);
                    errdefer {
                        var cleanup = capture_rb;
                        cleanup.deinit();
                    }

                    const ref_rb = try SampleRingBuffer.init(allocator, ref_buffer_capacity);
                    errdefer {
                        var cleanup = ref_rb;
                        cleanup.deinit();
                    }

                    return .{
                        .allocator = allocator,
                        .capture_rb = capture_rb,
                        .ref_rb = ref_rb,
                        .ref_write_scratch = &[_]i16{},
                    };
                }

                /// `deinit()` must not race with `start()`, `stop()`, `read()`,
                /// `createTrack()`, or active use of any returned track handle.
                pub fn deinit(self: *AudioSystem) void {
                    _ = self.stop() catch {};
                    if (self.ref_write_scratch.len > 0) self.allocator.free(self.ref_write_scratch);
                    self.capture_rb.deinit();
                    self.ref_rb.deinit();
                    if (self.playback) |playback| playback.deinit();
                    if (self.speaker_impl) |current_speaker| current_speaker.deinit();
                    if (self.mic_impl) |current_mic| current_mic.deinit();
                }

                pub fn setMic(self: *AudioSystem, new_mic: AudioSystem.Mic) Error!void {
                    if (self.hasActiveThreads()) return error.InvalidState;
                    if (self.mic_impl) |current_mic| current_mic.deinit();
                    self.mic_impl = new_mic;
                }

                /// Attaches or replaces the speaker implementation and creates the
                /// internal mixer to match that speaker's playback rate.
                pub fn setSpeaker(self: *AudioSystem, new_speaker: AudioSystem.Speaker) !void {
                    if (self.hasActiveThreads()) return error.InvalidState;
                    if (self.playback_config_locked) return error.InvalidState;

                    const playback = try DefaultMixer.init(.{
                        .allocator = self.allocator,
                        .output = .{
                            .rate = new_speaker.sampleRate(),
                            .channels = .mono,
                        },
                    });

                    if (self.playback) |current_playback| current_playback.deinit();
                    if (self.speaker_impl) |current_speaker| current_speaker.deinit();
                    self.playback = playback;
                    self.speaker_impl = new_speaker;
                }

                pub fn mic(self: AudioSystem) ?AudioSystem.Mic {
                    return self.mic_impl;
                }

                pub fn speaker(self: AudioSystem) ?AudioSystem.Speaker {
                    return self.speaker_impl;
                }

                pub fn micSampleRate(self: AudioSystem) Error!u32 {
                    const mic_impl = self.mic_impl orelse return error.InvalidState;
                    return mic_impl.sampleRate();
                }

                pub fn spkSampleRate(self: AudioSystem) Error!u32 {
                    const speaker_impl = self.speaker_impl orelse return error.InvalidState;
                    return speaker_impl.sampleRate();
                }

                pub fn micCount(self: AudioSystem) Error!u8 {
                    const mic_impl = self.mic_impl orelse return error.InvalidState;
                    return mic_impl.micCount();
                }

                /// Creates one playback track on the audio system's internal speaker mix
                /// path.
                pub fn createTrack(self: *AudioSystem, config: Track.Config) CreateTrackError!TrackHandle {
                    const playback = self.playback orelse return error.InvalidState;
                    const handle = try playback.createTrack(config);
                    self.playback_config_locked = true;
                    return handle;
                }

                /// `read(out)` drains processed microphone samples from the system's
                /// internal ring buffer populated by `readLoop`.
                pub fn read(self: *AudioSystem, out: []i16) Error!usize {
                    if (self.mic_impl == null) return error.InvalidState;
                    if (out.len == 0) return 0;

                    const n = readBuffered(&self.capture_rb, out);
                    if (n > 0) return n;

                    self.state_mu.lock();
                    const running = self.running;
                    const async_failed = self.async_failed;
                    self.state_mu.unlock();

                    if (async_failed) return error.Unexpected;
                    if (!running) return error.InvalidState;
                    return error.WouldBlock;
                }

                pub fn micGains(self: AudioSystem) Error!MicGains {
                    const mic_impl = self.mic_impl orelse return error.InvalidState;
                    return mic_impl.gains();
                }

                pub fn spkGain(self: AudioSystem) Error!?i8 {
                    const speaker_impl = self.speaker_impl orelse return error.InvalidState;
                    return speaker_impl.gain();
                }

                /// `gains_db` is ordered by microphone index. `null` leaves that channel
                /// unchanged.
                pub fn setMicGains(self: AudioSystem, gains_db: []const ?i8) Error!void {
                    const mic_impl = self.mic_impl orelse return error.InvalidState;
                    return mic_impl.setGains(gains_db);
                }

                pub fn setSpkGain(self: AudioSystem, gain_db: i8) Error!void {
                    const speaker_impl = self.speaker_impl orelse return error.InvalidState;
                    return speaker_impl.setGain(gain_db);
                }

                /// `start()` enables devices, then spawns a mic-side read loop and a
                /// speaker-side write loop so user `read()` calls only touch the internal
                /// ring buffer and never drive the I/O clocks directly.
                pub fn start(self: *AudioSystem) Error!void {
                    const maybe_mic = self.mic_impl;
                    const maybe_speaker = self.speaker_impl;
                    const read_enabled = maybe_mic != null;
                    const write_enabled = maybe_speaker != null;
                    var mic_enabled = false;
                    var speaker_enabled = false;

                    if (!read_enabled and !write_enabled) return error.InvalidState;
                    if (self.hasActiveThreads()) return error.InvalidState;

                    if (read_enabled and write_enabled) {
                        const mic_rate = maybe_mic.?.sampleRate();
                        const speaker_rate = maybe_speaker.?.sampleRate();
                        if (mic_rate == 0 or speaker_rate == 0) return error.InvalidState;
                        if (self.playback == null) return error.InvalidState;
                        try self.prepareLoopBuffers(mic_rate, speaker_rate);
                    } else {
                        discardBuffered(&self.capture_rb);
                        discardBuffered(&self.ref_rb);
                    }

                    self.state_mu.lock();
                    self.running = true;
                    self.async_failed = false;
                    self.state_mu.unlock();
                    errdefer {
                        self.state_mu.lock();
                        self.running = false;
                        self.read_thread = null;
                        self.write_thread = null;
                        self.state_mu.unlock();
                    }
                    errdefer {
                        if (mic_enabled) maybe_mic.?.disable() catch {};
                        if (speaker_enabled) maybe_speaker.?.disable() catch {};
                    }

                    if (maybe_speaker) |speaker_impl| {
                        try speaker_impl.enable();
                        speaker_enabled = true;
                    }
                    if (maybe_mic) |mic_impl| {
                        try mic_impl.enable();
                        mic_enabled = true;
                    }

                    const read_thread = if (read_enabled)
                        lib.Thread.spawn(.{}, AudioSystem.readLoop, .{self}) catch {
                            self.state_mu.lock();
                            self.running = false;
                            self.state_mu.unlock();
                            return error.Unexpected;
                        }
                    else
                        null;

                    const write_thread = if (write_enabled)
                        lib.Thread.spawn(.{}, AudioSystem.writeLoop, .{self}) catch {
                            self.state_mu.lock();
                            self.running = false;
                            self.state_mu.unlock();
                            if (maybe_mic) |mic_impl| mic_impl.disable() catch {};
                            if (maybe_speaker) |speaker_impl| speaker_impl.disable() catch {};
                            if (read_thread) |thread| thread.join();
                            return error.Unexpected;
                        }
                    else
                        null;

                    self.state_mu.lock();
                    self.read_thread = read_thread;
                    self.write_thread = write_thread;
                    self.state_mu.unlock();
                    mic_enabled = false;
                    speaker_enabled = false;
                }

                pub fn stop(self: *AudioSystem) Error!void {
                    const mic_impl = self.mic_impl;
                    const speaker_impl = self.speaker_impl;

                    self.state_mu.lock();
                    self.running = false;
                    const read_thread = self.read_thread;
                    const write_thread = self.write_thread;
                    self.read_thread = null;
                    self.write_thread = null;
                    self.state_mu.unlock();

                    if (mic_impl) |current_mic| current_mic.disable() catch {};
                    if (speaker_impl) |current_speaker| current_speaker.disable() catch {};

                    if (read_thread) |thread| thread.join();
                    if (write_thread) |thread| thread.join();
                }

                fn hasActiveThreads(self: *AudioSystem) bool {
                    self.state_mu.lock();
                    defer self.state_mu.unlock();
                    return self.running or self.read_thread != null or self.write_thread != null;
                }

                fn isRunning(self: *AudioSystem) bool {
                    self.state_mu.lock();
                    defer self.state_mu.unlock();
                    return self.running;
                }

                fn failAsync(self: *AudioSystem) void {
                    self.state_mu.lock();
                    self.running = false;
                    self.async_failed = true;
                    self.state_mu.unlock();

                    if (self.mic_impl) |current_mic| current_mic.disable() catch {};
                    if (self.speaker_impl) |current_speaker| current_speaker.disable() catch {};
                }

                fn prepareLoopBuffers(self: *AudioSystem, mic_rate: u32, speaker_rate: u32) Error!void {
                    discardBuffered(&self.capture_rb);
                    discardBuffered(&self.ref_rb);

                    const needed = referenceChunkLen(Speaker.frame_samples_per_channel, speaker_rate, mic_rate) catch |err| switch (err) {
                        error.Overflow => return error.Overflow,
                        else => return error.InvalidState,
                    };

                    if (self.ref_write_scratch.len == needed) return;
                    if (self.ref_write_scratch.len > 0) self.allocator.free(self.ref_write_scratch);
                    self.ref_write_scratch = self.allocator.alloc(i16, needed) catch return error.Unexpected;
                }

                fn readLoop(self: *AudioSystem) void {
                    const mic_impl = self.mic_impl orelse return;

                    var frame: Frame = .{
                        .mic = undefined,
                        .ref = null,
                    };
                    var ref_chunk: [samples_per_channel]i16 = @splat(0);
                    var processed: [samples_per_channel]i16 = undefined;

                    while (self.isRunning()) {
                        mic_impl.read(&frame) catch {
                            if (!self.isRunning()) return;
                            self.failAsync();
                            return;
                        };

                        @memset(ref_chunk[0..], 0);
                        const ref_n = readBuffered(&self.ref_rb, ref_chunk[0..]);
                        frame.ref = if (ref_n == 0) null else ref_chunk;

                        const n = ProcessorType.process(frame, processed[0..]) catch {
                            if (!self.isRunning()) return;
                            self.failAsync();
                            return;
                        };
                        if (n == 0) continue;
                        if (n > processed.len) {
                            self.failAsync();
                            return;
                        }

                        self.capture_rb.writeDroppingOldest(processed[0..n]);
                    }
                }

                fn writeLoop(self: *AudioSystem) void {
                    const speaker_impl = self.speaker_impl orelse return;
                    const playback = self.playback orelse return;
                    const speaker_rate = speaker_impl.sampleRate();
                    const maybe_mic = self.mic_impl;
                    const mic_rate = if (maybe_mic) |mic_impl| mic_impl.sampleRate() else 0;

                    var mix_chunk: Speaker.Frame = @splat(0);

                    while (self.isRunning()) {
                        @memset(mix_chunk[0..], 0);
                        _ = playback.read(mix_chunk[0..]) orelse 0;

                        writeSpeakerFrame(speaker_impl, mix_chunk[0..]) catch {
                            if (!self.isRunning()) return;
                            self.failAsync();
                            return;
                        };

                        if (maybe_mic != null) {
                            const ref_n = convertSpeakerChunkToMicRate(
                                mix_chunk[0..],
                                speaker_rate,
                                self.ref_write_scratch,
                                mic_rate,
                            ) catch {
                                if (!self.isRunning()) return;
                                self.failAsync();
                                return;
                            };
                            if (ref_n > 0) {
                                self.ref_rb.writeDroppingOldest(self.ref_write_scratch[0..ref_n]);
                            }
                        }

                        sleepForSamples(mix_chunk.len, speaker_rate);
                    }
                }

                fn readBuffered(buffer: *SampleRingBuffer, out: []i16) usize {
                    @memset(out, 0);
                    return buffer.mixInto(out, 1.0);
                }

                fn discardBuffered(buffer: *SampleRingBuffer) void {
                    var scratch: [256]i16 = @splat(0);
                    while (readBuffered(buffer, scratch[0..]) > 0) {}
                }

                fn writeSpeakerFrame(speaker_impl: AudioSystem.Speaker, frame: []const i16) Error!void {
                    var offset: usize = 0;
                    while (offset < frame.len) {
                        const written = try speaker_impl.write(frame[offset..]);
                        if (written == 0 or written > frame.len - offset) return error.Unexpected;
                        offset += written;
                    }
                }

                fn sleepForSamples(sample_count: usize, sample_rate: u32) void {
                    if (sample_count == 0 or sample_rate == 0) return;

                    const sleep_ns_128 = (@as(u128, sample_count) * @as(u128, lib.time.ns_per_s)) /
                        @as(u128, sample_rate);
                    if (sleep_ns_128 == 0) return;

                    const sleep_ns: u64 = @intCast(@min(sleep_ns_128, @as(u128, lib.math.maxInt(u64))));
                    lib.Thread.sleep(sleep_ns);
                }

                fn referenceChunkLen(input_len: usize, input_rate: u32, output_rate: u32) Error!usize {
                    if (input_len == 0 or input_rate == 0 or output_rate == 0) return error.InvalidState;

                    const output_len_128 = ((@as(u128, input_len) * @as(u128, output_rate)) +
                        @as(u128, input_rate) -
                        1) / @as(u128, input_rate);
                    if (output_len_128 > @as(u128, lib.math.maxInt(usize))) return error.Overflow;
                    return @intCast(output_len_128);
                }

                fn convertSpeakerChunkToMicRate(
                    input: []const i16,
                    input_rate: u32,
                    out: []i16,
                    output_rate: u32,
                ) Error!usize {
                    if (input.len == 0 or out.len == 0) return 0;
                    if (input_rate == 0 or output_rate == 0) return error.InvalidState;

                    const output_len = try referenceChunkLen(input.len, input_rate, output_rate);
                    if (output_len > out.len) return error.Overflow;

                    var i: usize = 0;
                    while (i < output_len) : (i += 1) {
                        const scaled = (@as(u128, i) * @as(u128, input_rate)) / @as(u128, output_rate);
                        const src_index: usize = if (scaled >= input.len)
                            input.len - 1
                        else
                            @intCast(scaled);
                        out[i] = input[src_index];
                    }
                    return output_len;
                }
            };
        }
    };
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        /// Upper bound for polling async read/write loops in these unit tests (success is usually ms-scale).
        const test_async_wait_ns: i128 = 5 * lib.time.ns_per_s;

        /// Poll `read` until samples arrive or `max_wait_ns` elapses. Avoids tying
        /// readiness to a fixed iteration count (brittle under slow scheduling / CI).
        fn pollReadSamples(system: anytype, out: []i16, max_wait_ns: i128) !usize {
            const Thread = lib.Thread;
            const time = lib.time;
            const deadline: i128 = time.nanoTimestamp() + max_wait_ns;
            while (time.nanoTimestamp() < deadline) {
                const n = system.read(out) catch |err| switch (err) {
                    error.WouldBlock => {
                        Thread.sleep(time.ns_per_ms);
                        continue;
                    },
                    else => return err,
                };
                if (n > 0) return n;
                Thread.sleep(time.ns_per_ms);
            }
            return 0;
        }

        fn waitSpeakerWrites(ctx: anytype, deadline_ns: i128) bool {
            const Thread = lib.Thread;
            const time = lib.time;
            while (time.nanoTimestamp() < deadline_ns) {
                ctx.mu.lock();
                const w = ctx.writes;
                ctx.mu.unlock();
                if (w > 0) return true;
                Thread.sleep(time.ns_per_ms);
            }
            return false;
        }

        fn startFailureResetsState(alloc: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const TestMic = MicMod.make(lib, 1, 4);
            const TestSpeaker = SpeakerMod.make(lib, 4);
            const ProcessorBackend = struct {
                fn process(frame: TestMic.Frame, out: []i16) Error!usize {
                    const n = @min(frame.mic[0].len, out.len);
                    @memcpy(out[0..n], frame.mic[0][0..n]);
                    return n;
                }
            };

            const Built = comptime blk: {
                var builder = Builder(lib).init();
                builder.configMic(1, 4);
                builder.configSpeaker(4);
                builder.setProcessor(&ProcessorBackend.process);
                break :blk builder.build();
            };

            const MicCtx = struct {
                enabled: bool = false,
            };
            const SpeakerCtx = struct {
                enabled: bool = false,
            };

            const MicBackend = struct {
                fn deinit(_: *anyopaque) void {}
                fn sampleRate(_: *anyopaque) u32 {
                    return 16000;
                }
                fn micCount(_: *anyopaque) u8 {
                    return 1;
                }
                fn read(_: *anyopaque, _: *TestMic.Frame) Error!void {
                    return;
                }
                fn gains(_: *anyopaque) TestMic.Gains {
                    return .{null};
                }
                fn setGains(_: *anyopaque, _: []const ?i8) Error!void {
                    return;
                }
                fn enable(ptr: *anyopaque) Error!void {
                    const ctx: *MicCtx = @ptrCast(@alignCast(ptr));
                    ctx.enabled = true;
                    return error.Unsupported;
                }
                fn disable(ptr: *anyopaque) Error!void {
                    const ctx: *MicCtx = @ptrCast(@alignCast(ptr));
                    ctx.enabled = false;
                }

                const vtable = TestMic.VTable{
                    .deinit = deinit,
                    .sampleRate = sampleRate,
                    .micCount = micCount,
                    .read = read,
                    .gains = gains,
                    .setGains = setGains,
                    .enable = enable,
                    .disable = disable,
                };
            };

            const SpeakerBackend = struct {
                fn deinit(_: *anyopaque) void {}
                fn sampleRate(_: *anyopaque) u32 {
                    return 16000;
                }
                fn write(_: *anyopaque, frame: []const i16) Error!usize {
                    return frame.len;
                }
                fn gain(_: *anyopaque) ?i8 {
                    return null;
                }
                fn setGain(_: *anyopaque, _: i8) Error!void {
                    return;
                }
                fn enable(ptr: *anyopaque) Error!void {
                    const ctx: *SpeakerCtx = @ptrCast(@alignCast(ptr));
                    ctx.enabled = true;
                }
                fn disable(ptr: *anyopaque) Error!void {
                    const ctx: *SpeakerCtx = @ptrCast(@alignCast(ptr));
                    ctx.enabled = false;
                }

                const vtable = TestSpeaker.VTable{
                    .deinit = deinit,
                    .sampleRate = sampleRate,
                    .write = write,
                    .gain = gain,
                    .setGain = setGain,
                    .enable = enable,
                    .disable = disable,
                };
            };

            var mic_ctx = MicCtx{};
            var speaker_ctx = SpeakerCtx{};
            var system = try Built.init(alloc);
            defer system.deinit();
            try system.setMic(TestMic.init(&mic_ctx, &MicBackend.vtable));
            try system.setSpeaker(TestSpeaker.init(&speaker_ctx, &SpeakerBackend.vtable));

            try testing.expectError(error.Unsupported, system.start());
            try testing.expect(!speaker_ctx.enabled);

            var out: [4]i16 = @splat(0);
            try testing.expectError(error.InvalidState, system.read(out[0..]));

            try system.setMic(TestMic.init(&mic_ctx, &MicBackend.vtable));
        }

        fn readLoopBuffersProcessedAudio(alloc: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const Thread = lib.Thread;
            const time = lib.time;
            const TestMic = MicMod.make(lib, 1, 4);
            const TestSpeaker = SpeakerMod.make(lib, 4);
            const ProcessorBackend = struct {
                fn process(frame: TestMic.Frame, out: []i16) Error!usize {
                    const n = @min(frame.mic[0].len, out.len);
                    @memcpy(out[0..n], frame.mic[0][0..n]);
                    return n;
                }
            };

            const Built = comptime blk: {
                var builder = Builder(lib).init();
                builder.configMic(1, 4);
                builder.configSpeaker(4);
                builder.setProcessor(&ProcessorBackend.process);
                break :blk builder.build();
            };

            const MicCtx = struct {
                next: i16 = 1,
                enabled: bool = false,
                mu: Thread.Mutex = .{},
            };
            const SpeakerCtx = struct {
                enabled: bool = false,
                writes: usize = 0,
                mu: Thread.Mutex = .{},
            };

            const MicBackend = struct {
                fn deinit(_: *anyopaque) void {}
                fn sampleRate(_: *anyopaque) u32 {
                    return 16000;
                }
                fn micCount(_: *anyopaque) u8 {
                    return 1;
                }
                fn read(ptr: *anyopaque, frame: *TestMic.Frame) Error!void {
                    const ctx: *MicCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    defer ctx.mu.unlock();
                    if (!ctx.enabled) return error.InvalidState;

                    var i: usize = 0;
                    while (i < frame.mic[0].len) : (i += 1) {
                        frame.mic[0][i] = ctx.next;
                        ctx.next = if (ctx.next == 30_000) 1 else ctx.next + 1;
                    }
                    frame.ref = null;
                }
                fn gains(_: *anyopaque) TestMic.Gains {
                    return .{null};
                }
                fn setGains(_: *anyopaque, _: []const ?i8) Error!void {
                    return;
                }
                fn enable(ptr: *anyopaque) Error!void {
                    const ctx: *MicCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    ctx.enabled = true;
                    ctx.mu.unlock();
                }
                fn disable(ptr: *anyopaque) Error!void {
                    const ctx: *MicCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    ctx.enabled = false;
                    ctx.mu.unlock();
                }

                const vtable = TestMic.VTable{
                    .deinit = deinit,
                    .sampleRate = sampleRate,
                    .micCount = micCount,
                    .read = read,
                    .gains = gains,
                    .setGains = setGains,
                    .enable = enable,
                    .disable = disable,
                };
            };

            const SpeakerBackend = struct {
                fn deinit(_: *anyopaque) void {}
                fn sampleRate(_: *anyopaque) u32 {
                    return 16000;
                }
                fn write(ptr: *anyopaque, frame: []const i16) Error!usize {
                    const ctx: *SpeakerCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    defer ctx.mu.unlock();
                    if (!ctx.enabled) return error.InvalidState;
                    ctx.writes += 1;
                    return frame.len;
                }
                fn gain(_: *anyopaque) ?i8 {
                    return null;
                }
                fn setGain(_: *anyopaque, _: i8) Error!void {
                    return;
                }
                fn enable(ptr: *anyopaque) Error!void {
                    const ctx: *SpeakerCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    ctx.enabled = true;
                    ctx.mu.unlock();
                }
                fn disable(ptr: *anyopaque) Error!void {
                    const ctx: *SpeakerCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    ctx.enabled = false;
                    ctx.mu.unlock();
                }

                const vtable = TestSpeaker.VTable{
                    .deinit = deinit,
                    .sampleRate = sampleRate,
                    .write = write,
                    .gain = gain,
                    .setGain = setGain,
                    .enable = enable,
                    .disable = disable,
                };
            };

            var mic_ctx = MicCtx{};
            var speaker_ctx = SpeakerCtx{};
            var system = try Built.init(alloc);
            defer system.deinit();
            try system.setMic(TestMic.init(&mic_ctx, &MicBackend.vtable));
            try system.setSpeaker(TestSpeaker.init(&speaker_ctx, &SpeakerBackend.vtable));

            try system.start();
            defer system.stop() catch {};

            var out: [8]i16 = @splat(0);
            const n = try pollReadSamples(&system, out[0..], test_async_wait_ns);
            try testing.expect(n > 0);
            try testing.expect(out[0] != 0);

            // writeLoop may lag readLoop; don't assert speaker writes synchronously.
            try testing.expect(waitSpeakerWrites(&speaker_ctx, time.nanoTimestamp() + test_async_wait_ns));
        }

        fn readReturnsWouldBlockWhenRunningAndEmpty(alloc: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const Thread = lib.Thread;
            const AtomicBool = lib.atomic.Value(bool);
            const TestMic = MicMod.make(lib, 1, 4);
            const TestSpeaker = SpeakerMod.make(lib, 4);
            const ProcessorBackend = struct {
                var emit = AtomicBool.init(false);

                fn process(frame: TestMic.Frame, out: []i16) Error!usize {
                    if (!emit.load(.acquire)) return 0;
                    const n = @min(frame.mic[0].len, out.len);
                    @memcpy(out[0..n], frame.mic[0][0..n]);
                    return n;
                }
            };

            const Built = comptime blk: {
                var builder = Builder(lib).init();
                builder.configMic(1, 4);
                builder.configSpeaker(4);
                builder.setProcessor(&ProcessorBackend.process);
                break :blk builder.build();
            };

            const MicCtx = struct {
                next: i16 = 1,
                enabled: bool = false,
                mu: Thread.Mutex = .{},
            };
            const SpeakerCtx = struct {
                enabled: bool = false,
                mu: Thread.Mutex = .{},
            };

            const MicBackend = struct {
                fn deinit(_: *anyopaque) void {}
                fn sampleRate(_: *anyopaque) u32 {
                    return 16000;
                }
                fn micCount(_: *anyopaque) u8 {
                    return 1;
                }
                fn read(ptr: *anyopaque, frame: *TestMic.Frame) Error!void {
                    const ctx: *MicCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    defer ctx.mu.unlock();
                    if (!ctx.enabled) return error.InvalidState;

                    var i: usize = 0;
                    while (i < frame.mic[0].len) : (i += 1) {
                        frame.mic[0][i] = ctx.next;
                        ctx.next = if (ctx.next == 30_000) 1 else ctx.next + 1;
                    }
                    frame.ref = null;
                }
                fn gains(_: *anyopaque) TestMic.Gains {
                    return .{null};
                }
                fn setGains(_: *anyopaque, _: []const ?i8) Error!void {
                    return;
                }
                fn enable(ptr: *anyopaque) Error!void {
                    const ctx: *MicCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    ctx.enabled = true;
                    ctx.mu.unlock();
                }
                fn disable(ptr: *anyopaque) Error!void {
                    const ctx: *MicCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    ctx.enabled = false;
                    ctx.mu.unlock();
                }

                const vtable = TestMic.VTable{
                    .deinit = deinit,
                    .sampleRate = sampleRate,
                    .micCount = micCount,
                    .read = read,
                    .gains = gains,
                    .setGains = setGains,
                    .enable = enable,
                    .disable = disable,
                };
            };

            const SpeakerBackend = struct {
                fn deinit(_: *anyopaque) void {}
                fn sampleRate(_: *anyopaque) u32 {
                    return 16000;
                }
                fn write(ptr: *anyopaque, frame: []const i16) Error!usize {
                    const ctx: *SpeakerCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    defer ctx.mu.unlock();
                    if (!ctx.enabled) return error.InvalidState;
                    return frame.len;
                }
                fn gain(_: *anyopaque) ?i8 {
                    return null;
                }
                fn setGain(_: *anyopaque, _: i8) Error!void {
                    return;
                }
                fn enable(ptr: *anyopaque) Error!void {
                    const ctx: *SpeakerCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    ctx.enabled = true;
                    ctx.mu.unlock();
                }
                fn disable(ptr: *anyopaque) Error!void {
                    const ctx: *SpeakerCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    ctx.enabled = false;
                    ctx.mu.unlock();
                }

                const vtable = TestSpeaker.VTable{
                    .deinit = deinit,
                    .sampleRate = sampleRate,
                    .write = write,
                    .gain = gain,
                    .setGain = setGain,
                    .enable = enable,
                    .disable = disable,
                };
            };

            var mic_ctx = MicCtx{};
            var speaker_ctx = SpeakerCtx{};
            ProcessorBackend.emit.store(false, .release);
            var system = try Built.init(alloc);
            defer system.deinit();
            try system.setMic(TestMic.init(&mic_ctx, &MicBackend.vtable));
            try system.setSpeaker(TestSpeaker.init(&speaker_ctx, &SpeakerBackend.vtable));

            try system.start();
            defer system.stop() catch {};

            var out: [4]i16 = @splat(0);
            try testing.expectError(error.WouldBlock, system.read(out[0..]));

            ProcessorBackend.emit.store(true, .release);
            const n = try pollReadSamples(&system, out[0..], test_async_wait_ns);
            try testing.expect(n > 0);
        }

        fn startAllowsMicOnlyMode(alloc: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const Thread = lib.Thread;
            const TestMic = MicMod.make(lib, 1, 4);
            const ProcessorBackend = struct {
                fn process(frame: TestMic.Frame, out: []i16) Error!usize {
                    const n = @min(frame.mic[0].len, out.len);
                    @memcpy(out[0..n], frame.mic[0][0..n]);
                    return n;
                }
            };

            const Built = comptime blk: {
                var builder = Builder(lib).init();
                builder.configMic(1, 4);
                builder.configSpeaker(4);
                builder.setProcessor(&ProcessorBackend.process);
                break :blk builder.build();
            };

            const MicCtx = struct {
                next: i16 = 1,
                enabled: bool = false,
                mu: Thread.Mutex = .{},
            };

            const MicBackend = struct {
                fn deinit(_: *anyopaque) void {}
                fn sampleRate(_: *anyopaque) u32 {
                    return 16000;
                }
                fn micCount(_: *anyopaque) u8 {
                    return 1;
                }
                fn read(ptr: *anyopaque, frame: *TestMic.Frame) Error!void {
                    const ctx: *MicCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    defer ctx.mu.unlock();
                    if (!ctx.enabled) return error.InvalidState;

                    var i: usize = 0;
                    while (i < frame.mic[0].len) : (i += 1) {
                        frame.mic[0][i] = ctx.next;
                        ctx.next = if (ctx.next == 30_000) 1 else ctx.next + 1;
                    }
                    frame.ref = null;
                }
                fn gains(_: *anyopaque) TestMic.Gains {
                    return .{null};
                }
                fn setGains(_: *anyopaque, _: []const ?i8) Error!void {
                    return;
                }
                fn enable(ptr: *anyopaque) Error!void {
                    const ctx: *MicCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    ctx.enabled = true;
                    ctx.mu.unlock();
                }
                fn disable(ptr: *anyopaque) Error!void {
                    const ctx: *MicCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    ctx.enabled = false;
                    ctx.mu.unlock();
                }

                const vtable = TestMic.VTable{
                    .deinit = deinit,
                    .sampleRate = sampleRate,
                    .micCount = micCount,
                    .read = read,
                    .gains = gains,
                    .setGains = setGains,
                    .enable = enable,
                    .disable = disable,
                };
            };

            var mic_ctx = MicCtx{};
            var system = try Built.init(alloc);
            defer system.deinit();
            try system.setMic(TestMic.init(&mic_ctx, &MicBackend.vtable));

            try system.start();
            defer system.stop() catch {};

            var out: [8]i16 = @splat(0);
            const n = try pollReadSamples(&system, out[0..], test_async_wait_ns);
            try testing.expect(n > 0);
            try testing.expect(out[0] != 0);
        }

        fn startAllowsSpeakerOnlyMode(alloc: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const Thread = lib.Thread;
            const time = lib.time;
            const TestSpeaker = SpeakerMod.make(lib, 4);
            const TestMic = MicMod.make(lib, 1, 4);
            const ProcessorBackend = struct {
                fn process(frame: TestMic.Frame, out: []i16) Error!usize {
                    const n = @min(frame.mic[0].len, out.len);
                    @memcpy(out[0..n], frame.mic[0][0..n]);
                    return n;
                }
            };

            const Built = comptime blk: {
                var builder = Builder(lib).init();
                builder.configMic(1, 4);
                builder.configSpeaker(4);
                builder.setProcessor(&ProcessorBackend.process);
                break :blk builder.build();
            };

            const SpeakerCtx = struct {
                enabled: bool = false,
                writes: usize = 0,
                mu: Thread.Mutex = .{},
            };

            const SpeakerBackend = struct {
                fn deinit(_: *anyopaque) void {}
                fn sampleRate(_: *anyopaque) u32 {
                    return 16000;
                }
                fn write(ptr: *anyopaque, frame: []const i16) Error!usize {
                    const ctx: *SpeakerCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    defer ctx.mu.unlock();
                    if (!ctx.enabled) return error.InvalidState;
                    ctx.writes += 1;
                    return frame.len;
                }
                fn gain(_: *anyopaque) ?i8 {
                    return null;
                }
                fn setGain(_: *anyopaque, _: i8) Error!void {
                    return;
                }
                fn enable(ptr: *anyopaque) Error!void {
                    const ctx: *SpeakerCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    ctx.enabled = true;
                    ctx.mu.unlock();
                }
                fn disable(ptr: *anyopaque) Error!void {
                    const ctx: *SpeakerCtx = @ptrCast(@alignCast(ptr));
                    ctx.mu.lock();
                    ctx.enabled = false;
                    ctx.mu.unlock();
                }

                const vtable = TestSpeaker.VTable{
                    .deinit = deinit,
                    .sampleRate = sampleRate,
                    .write = write,
                    .gain = gain,
                    .setGain = setGain,
                    .enable = enable,
                    .disable = disable,
                };
            };

            var speaker_ctx = SpeakerCtx{};
            var system = try Built.init(alloc);
            defer system.deinit();
            try system.setSpeaker(TestSpeaker.init(&speaker_ctx, &SpeakerBackend.vtable));

            const handle = try system.createTrack(.{});
            defer handle.track.deinit();
            defer handle.ctrl.deinit();
            try handle.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 1, 2, 3, 4 });

            try system.start();
            defer system.stop() catch {};

            var out: [4]i16 = @splat(0);
            try testing.expectError(error.InvalidState, system.read(out[0..]));

            const deadline = time.nanoTimestamp() + test_async_wait_ns;
            try testing.expect(waitSpeakerWrites(&speaker_ctx, deadline));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("start_failure_resets_state", glib.testing.TestRunner.fromFn(lib, 256 * 1024, struct {
                fn run(_: *glib.testing.T, case_allocator: lib.mem.Allocator) !void {
                    try TestCase.startFailureResetsState(case_allocator);
                }
            }.run));
            if (!t.wait()) return false;
            t.run("readLoop_buffers_processed_audio", glib.testing.TestRunner.fromFn(lib, 256 * 1024, struct {
                fn run(_: *glib.testing.T, case_allocator: lib.mem.Allocator) !void {
                    try TestCase.readLoopBuffersProcessedAudio(case_allocator);
                }
            }.run));
            if (!t.wait()) return false;
            t.run("read_returns_wouldblock_when_running_and_empty", glib.testing.TestRunner.fromFn(lib, 256 * 1024, struct {
                fn run(_: *glib.testing.T, case_allocator: lib.mem.Allocator) !void {
                    try TestCase.readReturnsWouldBlockWhenRunningAndEmpty(case_allocator);
                }
            }.run));
            if (!t.wait()) return false;
            t.run("start_allows_mic_only_mode", glib.testing.TestRunner.fromFn(lib, 256 * 1024, struct {
                fn run(_: *glib.testing.T, case_allocator: lib.mem.Allocator) !void {
                    try TestCase.startAllowsMicOnlyMode(case_allocator);
                }
            }.run));
            if (!t.wait()) return false;
            t.run("start_allows_speaker_only_mode", glib.testing.TestRunner.fromFn(lib, 256 * 1024, struct {
                fn run(_: *glib.testing.T, case_allocator: lib.mem.Allocator) !void {
                    try TestCase.startAllowsSpeakerOnlyMode(case_allocator);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
