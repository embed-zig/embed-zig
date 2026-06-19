//! audio.AudioSystem — type-erased audio-system surface.

const drivers = @import("drivers");
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

pub fn Builder(comptime grt: type) type {
    return struct {
        const Self = @This();

        mic: ?type = null,
        speaker: ?type = null,
        processor: ?type = null,

        pub fn init() Self {
            return .{};
        }

        pub fn configMic(self: *Self, comptime mic_count: usize, comptime samples_per_channel: usize) void {
            self.mic = MicMod.make(grt, mic_count, samples_per_channel);
        }

        pub fn configSpeaker(self: *Self, comptime samples_per_channel: usize) void {
            self.speaker = SpeakerMod.make(grt, samples_per_channel);
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
                const DefaultMixer = Mixer.make(grt);
                const SampleRingBuffer = RingBufferMod.make(grt);
                const log = grt.std.log.scoped(.audio_system);
                const capture_buffer_capacity = samples_per_channel * 16;
                const ref_buffer_capacity = samples_per_channel * 16;
                const raw_frame_buffer_capacity = 4;
                const debug_report_interval = 100;

                pub const Mic = MicType;
                pub const Speaker = SpeakerType;
                pub const Frame = FrameType;
                pub const MicGains = MicType.Gains;
                pub const Format = Mixer.Format;
                pub const Track = Mixer.Track;
                pub const TrackCtrl = Mixer.TrackCtrl;
                pub const TrackHandle = Mixer.TrackHandle;
                pub const CreateTrackError = Mixer.CreateTrackError;
                pub const frame_mic_count: usize = mic_count;
                pub const frame_samples_per_channel: usize = samples_per_channel;

                pub const Config = struct {
                    read_task: glib.task.Options = .{},
                    processor_task: glib.task.Options = .{},
                    write_task: glib.task.Options = .{},
                    soft_ref_delay_samples: usize = 0,
                };

                const RawFrameBuffer = struct {
                    allocator: glib.std.mem.Allocator,
                    items: []Frame,
                    head: usize = 0,
                    len: usize = 0,
                    mutex: grt.std.Thread.Mutex = .{},

                    fn init(allocator: glib.std.mem.Allocator, capacity: usize) !RawFrameBuffer {
                        return .{
                            .allocator = allocator,
                            .items = try allocator.alloc(Frame, capacity),
                        };
                    }

                    fn deinit(self: *RawFrameBuffer) void {
                        self.allocator.free(self.items);
                        self.* = undefined;
                    }

                    fn writeDroppingOldest(self: *RawFrameBuffer, frame: Frame) bool {
                        self.mutex.lock();
                        defer self.mutex.unlock();

                        if (self.items.len == 0) return true;
                        var dropped = false;
                        if (self.len == self.items.len) {
                            self.consumeLocked(1);
                            dropped = true;
                        }

                        const tail = (self.head + self.len) % self.items.len;
                        self.items[tail] = frame;
                        self.len += 1;
                        return dropped;
                    }

                    fn read(self: *RawFrameBuffer, frame: *Frame) bool {
                        self.mutex.lock();
                        defer self.mutex.unlock();

                        if (self.len == 0) return false;
                        frame.* = self.items[self.head];
                        self.consumeLocked(1);
                        return true;
                    }

                    fn discard(self: *RawFrameBuffer) void {
                        self.mutex.lock();
                        defer self.mutex.unlock();
                        self.head = 0;
                        self.len = 0;
                    }

                    fn consumeLocked(self: *RawFrameBuffer, n: usize) void {
                        const actual = @min(n, self.len);
                        if (actual == 0) return;
                        self.head = (self.head + actual) % self.items.len;
                        self.len -= actual;
                        if (self.len == 0) self.head = 0;
                    }
                };

                allocator: glib.std.mem.Allocator,
                mic_impl: ?AudioSystem.Mic = null,
                speaker_impl: ?AudioSystem.Speaker = null,
                playback: ?Mixer = null,
                capture_rb: SampleRingBuffer,
                raw_rb: RawFrameBuffer,
                ref_rb: SampleRingBuffer,
                ref_write_scratch: []i16,
                state_mu: grt.std.Thread.Mutex = .{},
                running: bool = false,
                async_failed: bool = false,
                playback_config_locked: bool = false,
                read_task: ?grt.task.Handle = null,
                processor_task: ?grt.task.Handle = null,
                write_task: ?grt.task.Handle = null,
                read_task_options: glib.task.Options = .{},
                processor_task_options: glib.task.Options = .{},
                write_task_options: glib.task.Options = .{},
                soft_ref_delay_samples: usize = 0,

                pub fn init(allocator: glib.std.mem.Allocator, config: Config) !AudioSystem {
                    const capture_rb = try SampleRingBuffer.init(allocator, capture_buffer_capacity);
                    errdefer {
                        var cleanup = capture_rb;
                        cleanup.deinit();
                    }

                    const raw_rb = try RawFrameBuffer.init(allocator, raw_frame_buffer_capacity);
                    errdefer {
                        var cleanup = raw_rb;
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
                        .raw_rb = raw_rb,
                        .ref_rb = ref_rb,
                        .ref_write_scratch = &[_]i16{},
                        .read_task_options = config.read_task,
                        .processor_task_options = config.processor_task,
                        .write_task_options = config.write_task,
                        .soft_ref_delay_samples = config.soft_ref_delay_samples,
                    };
                }

                /// `deinit()` must not race with `start()`, `stop()`, `read()`,
                /// `createTrack()`, or active use of any returned track handle.
                pub fn deinit(self: *AudioSystem) void {
                    _ = self.stop() catch {};
                    if (self.ref_write_scratch.len > 0) self.allocator.free(self.ref_write_scratch);
                    self.capture_rb.deinit();
                    self.raw_rb.deinit();
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
                pub fn createTrack(self: *AudioSystem, config: Mixer.Track.Config) Mixer.CreateTrackError!Mixer.TrackHandle {
                    const playback = self.playback orelse return error.InvalidState;
                    const handle = try playback.createTrack(config);
                    self.playback_config_locked = true;
                    return handle;
                }

                /// `read(out)` drains processed microphone samples from the system's
                /// internal ring buffer populated by `processLoop`.
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

                pub fn discardReadBuffer(self: *AudioSystem) void {
                    self.raw_rb.discard();
                    discardBuffered(&self.capture_rb);
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

                /// `start()` enables devices, then starts a mic-side read task and a
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
                        self.read_task = null;
                        self.processor_task = null;
                        self.write_task = null;
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

                    const read_task = if (read_enabled)
                        grt.task.go("audio/read", self.read_task_options, glib.task.Routine.init(self, AudioSystem.readLoop)) catch |err| {
                            log.err("start audio/read task failed: {s}", .{@errorName(err)});
                            self.state_mu.lock();
                            self.running = false;
                            self.state_mu.unlock();
                            return error.Unexpected;
                        }
                    else
                        null;

                    const processor_task = if (read_enabled)
                        grt.task.go("audio/processor", self.processor_task_options, glib.task.Routine.init(self, AudioSystem.processLoop)) catch |err| {
                            log.err("start audio/processor task failed: {s}", .{@errorName(err)});
                            self.state_mu.lock();
                            self.running = false;
                            self.state_mu.unlock();
                            if (maybe_mic) |mic_impl| mic_impl.disable() catch {};
                            if (maybe_speaker) |speaker_impl| speaker_impl.disable() catch {};
                            if (read_task) |task| task.join();
                            return error.Unexpected;
                        }
                    else
                        null;

                    const write_task = if (write_enabled)
                        grt.task.go("audio/write", self.write_task_options, glib.task.Routine.init(self, AudioSystem.writeLoop)) catch |err| {
                            log.err("start audio/write task failed: {s}", .{@errorName(err)});
                            self.state_mu.lock();
                            self.running = false;
                            self.state_mu.unlock();
                            if (maybe_mic) |mic_impl| mic_impl.disable() catch {};
                            if (maybe_speaker) |speaker_impl| speaker_impl.disable() catch {};
                            if (read_task) |task| task.join();
                            if (processor_task) |task| task.join();
                            return error.Unexpected;
                        }
                    else
                        null;

                    self.state_mu.lock();
                    self.read_task = read_task;
                    self.processor_task = processor_task;
                    self.write_task = write_task;
                    self.state_mu.unlock();
                    mic_enabled = false;
                    speaker_enabled = false;
                }

                pub fn stop(self: *AudioSystem) Error!void {
                    const mic_impl = self.mic_impl;
                    const speaker_impl = self.speaker_impl;

                    self.state_mu.lock();
                    self.running = false;
                    const read_task = self.read_task;
                    const processor_task = self.processor_task;
                    const write_task = self.write_task;
                    self.read_task = null;
                    self.processor_task = null;
                    self.write_task = null;
                    self.state_mu.unlock();

                    if (mic_impl) |current_mic| current_mic.disable() catch {};
                    if (speaker_impl) |current_speaker| current_speaker.disable() catch {};

                    if (read_task) |task| task.join();
                    if (processor_task) |task| task.join();
                    if (write_task) |task| task.join();
                }

                fn hasActiveThreads(self: *AudioSystem) bool {
                    self.state_mu.lock();
                    defer self.state_mu.unlock();
                    return self.running or self.read_task != null or self.processor_task != null or self.write_task != null;
                }

                fn isRunning(self: *AudioSystem) bool {
                    self.state_mu.lock();
                    defer self.state_mu.unlock();
                    return self.running;
                }

                fn failAsync(self: *AudioSystem) void {
                    log.err("async failure; disabling devices", .{});
                    self.state_mu.lock();
                    self.running = false;
                    self.async_failed = true;
                    self.state_mu.unlock();

                    if (self.mic_impl) |current_mic| current_mic.disable() catch {};
                    if (self.speaker_impl) |current_speaker| current_speaker.disable() catch {};
                }

                fn prepareLoopBuffers(self: *AudioSystem, mic_rate: u32, speaker_rate: u32) Error!void {
                    discardBuffered(&self.capture_rb);
                    self.raw_rb.discard();
                    discardBuffered(&self.ref_rb);
                    try self.seedSoftRefDelay();

                    const converted_len = referenceChunkLen(Speaker.frame_samples_per_channel, speaker_rate, mic_rate) catch |err| switch (err) {
                        error.Overflow => return error.Overflow,
                        else => return error.InvalidState,
                    };
                    const needed = @max(Speaker.frame_samples_per_channel, converted_len);

                    if (self.ref_write_scratch.len == needed) return;
                    if (self.ref_write_scratch.len > 0) self.allocator.free(self.ref_write_scratch);
                    self.ref_write_scratch = self.allocator.alloc(i16, needed) catch return error.Unexpected;
                }

                fn seedSoftRefDelay(self: *AudioSystem) Error!void {
                    if (self.soft_ref_delay_samples == 0) return;
                    if (self.soft_ref_delay_samples >= ref_buffer_capacity) return error.InvalidState;

                    var zeros: [samples_per_channel]i16 = @splat(0);
                    var remaining = self.soft_ref_delay_samples;
                    while (remaining > 0) {
                        const n = @min(remaining, zeros.len);
                        self.ref_rb.writeDroppingOldest(zeros[0..n]);
                        remaining -= n;
                    }
                }

                fn readLoop(self: *AudioSystem) void {
                    const mic_impl = self.mic_impl orelse return;

                    var frame: Frame = .{
                        .mic = undefined,
                        .ref = null,
                    };
                    var ref_chunk: [samples_per_channel]i16 = @splat(0);
                    var frames: usize = 0;
                    var raw_drops: usize = 0;
                    var soft_refs: usize = 0;
                    var soft_ref_samples: usize = 0;

                    while (self.isRunning()) {
                        frame.ref = null;
                        mic_impl.read(&frame) catch |err| {
                            if (!self.isRunning()) return;
                            log.err("mic read failed: {s}", .{@errorName(err)});
                            self.failAsync();
                            return;
                        };

                        if (frame.ref == null) {
                            @memset(ref_chunk[0..], 0);
                            soft_ref_samples += readBuffered(&self.ref_rb, ref_chunk[0..]);
                            soft_refs += 1;
                            frame.ref = ref_chunk;
                        }

                        frames += 1;
                        if (self.raw_rb.writeDroppingOldest(frame)) raw_drops += 1;
                        if (frames % debug_report_interval == 0) {
                            log.info(
                                "audio dbg read frames={d} raw_drop={d} soft_ref={d} soft_ref_samples={d}",
                                .{ frames, raw_drops, soft_refs, soft_ref_samples },
                            );
                        }
                        yieldToScheduler();
                    }
                }

                fn processLoop(self: *AudioSystem) void {
                    var frame: Frame = .{
                        .mic = undefined,
                        .ref = null,
                    };
                    var processed: [samples_per_channel]i16 = undefined;
                    var frames: usize = 0;
                    var processed_samples: usize = 0;
                    var raw_empty: usize = 0;
                    var process_total_ns: glib.time.duration.Duration = 0;
                    var process_max_ns: glib.time.duration.Duration = 0;

                    while (self.isRunning()) {
                        if (!self.raw_rb.read(&frame)) {
                            raw_empty += 1;
                            yieldToScheduler();
                            continue;
                        }

                        const process_started = grt.time.instant.now();
                        const n = ProcessorType.process(frame, processed[0..]) catch |err| {
                            if (!self.isRunning()) return;
                            log.err("processor failed: {s}", .{@errorName(err)});
                            self.failAsync();
                            return;
                        };
                        const process_elapsed = glib.time.instant.sub(grt.time.instant.now(), process_started);
                        process_total_ns += process_elapsed;
                        process_max_ns = @max(process_max_ns, process_elapsed);
                        frames += 1;
                        if (n == 0) {
                            yieldToScheduler();
                            continue;
                        }
                        if (n > processed.len) {
                            self.failAsync();
                            return;
                        }

                        processed_samples += n;
                        self.capture_rb.writeDroppingOldest(processed[0..n]);
                        if (frames % debug_report_interval == 0) {
                            log.info(
                                "audio dbg process frames={d} samples={d} raw_empty={d} avg_us={d} max_us={d}",
                                .{
                                    frames,
                                    processed_samples,
                                    raw_empty,
                                    durationToUs(@divTrunc(process_total_ns, @as(glib.time.duration.Duration, @intCast(frames)))),
                                    durationToUs(process_max_ns),
                                },
                            );
                        }
                        yieldToScheduler();
                    }
                }

                fn writeLoop(self: *AudioSystem) void {
                    const speaker_impl = self.speaker_impl orelse return;
                    const playback = self.playback orelse return;
                    const speaker_rate = speaker_impl.sampleRate();
                    const maybe_mic = self.mic_impl;
                    const mic_rate = if (maybe_mic) |mic_impl| mic_impl.sampleRate() else 0;

                    var mix_chunk: Speaker.Frame = @splat(0);
                    var ref_mix_chunk: Speaker.Frame = @splat(0);
                    var frames: usize = 0;
                    var mixed_samples: usize = 0;
                    var ref_samples: usize = 0;
                    var idle: usize = 0;

                    while (self.isRunning()) {
                        @memset(mix_chunk[0..], 0);
                        @memset(ref_mix_chunk[0..], 0);
                        const mixed_n = if (maybe_mic != null)
                            playback.readWithReference(mix_chunk[0..], ref_mix_chunk[0..]) orelse 0
                        else
                            playback.read(mix_chunk[0..]) orelse 0;
                        if (mixed_n == 0) {
                            idle += 1;
                            sleepForSamples(mix_chunk.len, speaker_rate);
                            continue;
                        }

                        frames += 1;
                        mixed_samples += mixed_n;
                        if (maybe_mic != null) {
                            const ref_n = convertSpeakerChunkToMicRate(
                                ref_mix_chunk[0..mixed_n],
                                speaker_rate,
                                self.ref_write_scratch,
                                mic_rate,
                            ) catch |err| {
                                if (!self.isRunning()) return;
                                log.err("convert speaker ref failed: {s}", .{@errorName(err)});
                                self.failAsync();
                                return;
                            };
                            if (ref_n > 0) {
                                self.ref_rb.writeDroppingOldest(self.ref_write_scratch[0..ref_n]);
                                ref_samples += ref_n;
                            }
                        }

                        writeSpeakerFrame(speaker_impl, mix_chunk[0..mixed_n]) catch |err| {
                            if (!self.isRunning()) return;
                            log.err("speaker write failed: {s}", .{@errorName(err)});
                            self.failAsync();
                            return;
                        };
                        if (frames % debug_report_interval == 0) {
                            log.info(
                                "audio dbg write frames={d} mixed_samples={d} ref_samples={d} idle={d}",
                                .{ frames, mixed_samples, ref_samples, idle },
                            );
                        }
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

                    const duration = durationForSamples(sample_count, sample_rate);
                    if (duration <= 0) return;
                    grt.std.Thread.sleep(@intCast(duration));
                }

                fn yieldToScheduler() void {
                    grt.std.Thread.sleep(1 * grt.time.duration.MilliSecond);
                }

                fn durationForSamples(sample_count: usize, sample_rate: u32) glib.time.duration.Duration {
                    if (sample_count == 0 or sample_rate == 0) return 0;

                    const duration_128 = (@as(u128, sample_count) * @as(u128, @intCast(grt.time.duration.Second))) /
                        @as(u128, sample_rate);
                    return @intCast(@min(duration_128, @as(u128, @intCast(glib.time.duration.Maximum))));
                }

                fn durationToUs(duration: glib.time.duration.Duration) i64 {
                    return @divTrunc(duration, glib.time.duration.MicroSecond);
                }

                fn referenceChunkLen(input_len: usize, input_rate: u32, output_rate: u32) Error!usize {
                    if (input_len == 0 or input_rate == 0 or output_rate == 0) return error.InvalidState;

                    const output_len_128 = ((@as(u128, input_len) * @as(u128, output_rate)) +
                        @as(u128, input_rate) -
                        1) / @as(u128, input_rate);
                    if (output_len_128 > @as(u128, grt.std.math.maxInt(usize))) return error.Overflow;
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

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        /// Upper bound for polling async read/write loops in these unit tests (success is usually ms-scale).
        const test_async_wait: glib.time.duration.Duration = 5 * grt.time.duration.Second;

        /// Poll `read` until samples arrive or `max_wait` elapses. Avoids tying
        /// readiness to a fixed iteration count (brittle under slow scheduling / CI).
        fn pollReadSamples(system: anytype, out: []i16, max_wait: glib.time.duration.Duration) !usize {
            const Thread = grt.std.Thread;
            const deadline = glib.time.instant.add(grt.time.instant.now(), max_wait);
            while (grt.time.instant.now() < deadline) {
                const n = system.read(out) catch |err| switch (err) {
                    error.WouldBlock => {
                        Thread.sleep(@intCast(grt.time.duration.MilliSecond));
                        continue;
                    },
                    else => return err,
                };
                if (n > 0) return n;
                Thread.sleep(@intCast(grt.time.duration.MilliSecond));
            }
            return 0;
        }

        fn waitSpeakerWrites(ctx: anytype, deadline: glib.time.instant.Time) bool {
            const Thread = grt.std.Thread;
            while (grt.time.instant.now() < deadline) {
                ctx.mu.lock();
                const w = ctx.writes;
                ctx.mu.unlock();
                if (w > 0) return true;
                Thread.sleep(@intCast(grt.time.duration.MilliSecond));
            }
            return false;
        }

        fn waitMicReads(ctx: anytype, min_reads: usize, deadline: glib.time.instant.Time) bool {
            const Thread = grt.std.Thread;
            while (grt.time.instant.now() < deadline) {
                ctx.mu.lock();
                const reads = ctx.reads;
                ctx.mu.unlock();
                if (reads >= min_reads) return true;
                Thread.sleep(@intCast(grt.time.duration.MilliSecond));
            }
            return false;
        }

        fn gainTableFuncAppliesThroughAudioSystem(alloc: glib.std.mem.Allocator) !void {
            const TestMic = MicMod.make(grt, 2, 1);
            const TestSpeaker = SpeakerMod.make(grt, 1);
            const ProcessorBackend = struct {
                fn process(_: TestMic.Frame, _: []i16) Error!usize {
                    return 0;
                }
            };
            const GainTable = struct {
                fn lower(gain_db: i8) i8 {
                    return gain_db - 12;
                }
            };
            const FakeI2s = struct {
                pub fn write(_: *@This(), data: []const u8) drivers.I2s.Error!usize {
                    return data.len;
                }

                pub fn read(_: *@This(), buf: []u8) drivers.I2s.Error!usize {
                    return buf.len;
                }
            };

            const Built = comptime blk: {
                var builder = Builder(grt).init();
                builder.configMic(2, 1);
                builder.configSpeaker(1);
                builder.setProcessor(&ProcessorBackend.process);
                break :blk builder.build();
            };

            var mic_i2s = FakeI2s{};
            var mic_stream = try drivers.I2s.init(alloc, &mic_i2s, .{
                .slots_per_frame = 2,
                .bytes_per_slot = 2,
                .buffer_frame_count = 1,
            });
            defer mic_stream.deinit();
            var mic_output = TestMic.i2s(.{
                .stream = &mic_stream,
                .sample_rate = 16_000,
                .mic_channels = .{
                    .{ .slot = 0 },
                    .{ .slot = 1 },
                },
            });
            var mic = mic_output.mic();
            mic.setGainTableFunc(&GainTable.lower);

            var speaker_i2s = FakeI2s{};
            var speaker_stream = try drivers.I2s.init(alloc, &speaker_i2s, .{
                .slots_per_frame = 1,
                .bytes_per_slot = 2,
                .buffer_frame_count = 1,
            });
            defer speaker_stream.deinit();
            const slots = [_]TestSpeaker.I2s.Slot{
                .{ .index = 0 },
            };
            const channels = [_]TestSpeaker.I2s.Channel{
                .{ .slots = &slots },
            };
            var speaker_output = TestSpeaker.i2s(.{
                .stream = &speaker_stream,
                .sample_rate = 16_000,
                .channels = &channels,
            });
            var speaker = speaker_output.speaker();
            speaker.setGainTableFunc(&GainTable.lower);

            var system = try Built.init(alloc, .{});
            defer system.deinit();
            try system.setMic(mic);
            try system.setSpeaker(speaker);

            try system.setMicGains(&.{ 10, null });
            try grt.std.testing.expectEqual(TestMic.Gains{ -2, null }, try system.micGains());

            try system.setSpkGain(3);
            try grt.std.testing.expectEqual(@as(?i8, -9), try system.spkGain());
        }

        fn startFailureResetsState(alloc: glib.std.mem.Allocator) !void {
            const TestMic = MicMod.make(grt, 1, 4);
            const TestSpeaker = SpeakerMod.make(grt, 4);
            const ProcessorBackend = struct {
                fn process(frame: TestMic.Frame, out: []i16) Error!usize {
                    const n = @min(frame.mic[0].len, out.len);
                    @memcpy(out[0..n], frame.mic[0][0..n]);
                    return n;
                }
            };

            const Built = comptime blk: {
                var builder = Builder(grt).init();
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
            var system = try Built.init(alloc, .{});
            defer system.deinit();
            try system.setMic(TestMic.init(&mic_ctx, &MicBackend.vtable));
            try system.setSpeaker(TestSpeaker.init(&speaker_ctx, &SpeakerBackend.vtable));

            try grt.std.testing.expectError(error.Unsupported, system.start());
            try grt.std.testing.expect(!speaker_ctx.enabled);

            var out: [4]i16 = @splat(0);
            try grt.std.testing.expectError(error.InvalidState, system.read(out[0..]));

            try system.setMic(TestMic.init(&mic_ctx, &MicBackend.vtable));
        }

        fn readLoopBuffersProcessedAudio(alloc: glib.std.mem.Allocator) !void {
            const Thread = grt.std.Thread;
            const TestMic = MicMod.make(grt, 1, 4);
            const TestSpeaker = SpeakerMod.make(grt, 4);
            const ProcessorBackend = struct {
                fn process(frame: TestMic.Frame, out: []i16) Error!usize {
                    const n = @min(frame.mic[0].len, out.len);
                    @memcpy(out[0..n], frame.mic[0][0..n]);
                    return n;
                }
            };

            const Built = comptime blk: {
                var builder = Builder(grt).init();
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
            var system = try Built.init(alloc, .{});
            defer system.deinit();
            try system.setMic(TestMic.init(&mic_ctx, &MicBackend.vtable));
            try system.setSpeaker(TestSpeaker.init(&speaker_ctx, &SpeakerBackend.vtable));

            try system.start();
            defer system.stop() catch {};

            var out: [8]i16 = @splat(0);
            const n = try pollReadSamples(&system, out[0..], test_async_wait);
            try grt.std.testing.expect(n > 0);
            try grt.std.testing.expect(out[0] != 0);

            speaker_ctx.mu.lock();
            const speaker_writes = speaker_ctx.writes;
            speaker_ctx.mu.unlock();
            try grt.std.testing.expectEqual(@as(usize, 0), speaker_writes);
        }

        fn slowProcessorDoesNotBlockMicReads(alloc: glib.std.mem.Allocator) !void {
            const Thread = grt.std.Thread;
            const TestMic = MicMod.make(grt, 1, 4);
            const ProcessorBackend = struct {
                fn process(frame: TestMic.Frame, out: []i16) Error!usize {
                    Thread.sleep(@intCast(30 * grt.time.duration.MilliSecond));
                    const n = @min(frame.mic[0].len, out.len);
                    @memcpy(out[0..n], frame.mic[0][0..n]);
                    return n;
                }
            };

            const Built = comptime blk: {
                var builder = Builder(grt).init();
                builder.configMic(1, 4);
                builder.configSpeaker(4);
                builder.setProcessor(&ProcessorBackend.process);
                break :blk builder.build();
            };

            const MicCtx = struct {
                reads: usize = 0,
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
                    ctx.reads += 1;
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
            var system = try Built.init(alloc, .{});
            defer system.deinit();
            try system.setMic(TestMic.init(&mic_ctx, &MicBackend.vtable));

            try system.start();
            defer system.stop() catch {};

            const deadline = glib.time.instant.add(grt.time.instant.now(), 120 * grt.time.duration.MilliSecond);
            try grt.std.testing.expect(waitMicReads(&mic_ctx, 8, deadline));
        }

        fn readReturnsWouldBlockWhenRunningAndEmpty(alloc: glib.std.mem.Allocator) !void {
            const Thread = grt.std.Thread;
            const AtomicBool = grt.std.atomic.Value(bool);
            const TestMic = MicMod.make(grt, 1, 4);
            const TestSpeaker = SpeakerMod.make(grt, 4);
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
                var builder = Builder(grt).init();
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
            var system = try Built.init(alloc, .{});
            defer system.deinit();
            try system.setMic(TestMic.init(&mic_ctx, &MicBackend.vtable));
            try system.setSpeaker(TestSpeaker.init(&speaker_ctx, &SpeakerBackend.vtable));

            try system.start();
            defer system.stop() catch {};

            var out: [4]i16 = @splat(0);
            try grt.std.testing.expectError(error.WouldBlock, system.read(out[0..]));

            ProcessorBackend.emit.store(true, .release);
            const n = try pollReadSamples(&system, out[0..], test_async_wait);
            try grt.std.testing.expect(n > 0);
        }

        fn readLoopResetsMissingMicRef(alloc: glib.std.mem.Allocator) !void {
            const Thread = grt.std.Thread;
            const TestMic = MicMod.make(grt, 1, 4);
            const TestSpeaker = SpeakerMod.make(grt, 4);
            const ProcessorBackend = struct {
                fn process(frame: TestMic.Frame, out: []i16) Error!usize {
                    const ref = frame.ref orelse return error.InvalidState;
                    const n = @min(ref.len, out.len);
                    @memcpy(out[0..n], ref[0..n]);
                    return n;
                }
            };

            const Built = comptime blk: {
                var builder = Builder(grt).init();
                builder.configMic(1, 4);
                builder.configSpeaker(4);
                builder.setProcessor(&ProcessorBackend.process);
                break :blk builder.build();
            };

            const MicCtx = struct {
                reads: usize = 0,
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

                    @memset(frame.mic[0][0..], 1);
                    if (ctx.reads == 0) {
                        frame.ref = [_]i16{9} ** 4;
                    }
                    ctx.reads += 1;
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
            var system = try Built.init(alloc, .{});
            defer system.deinit();
            try system.setMic(TestMic.init(&mic_ctx, &MicBackend.vtable));
            try system.setSpeaker(TestSpeaker.init(&speaker_ctx, &SpeakerBackend.vtable));

            try system.start();
            defer system.stop() catch {};

            const deadline = glib.time.instant.add(grt.time.instant.now(), test_async_wait);
            try grt.std.testing.expect(waitMicReads(&mic_ctx, 3, deadline));
            system.discardReadBuffer();

            var out: [4]i16 = @splat(9);
            const n = try pollReadSamples(&system, out[0..], test_async_wait);
            try grt.std.testing.expect(n > 0);
            try grt.std.testing.expectEqual(@as(i16, 0), out[0]);
        }

        fn startAllowsMicOnlyMode(alloc: glib.std.mem.Allocator) !void {
            const Thread = grt.std.Thread;
            const TestMic = MicMod.make(grt, 1, 4);
            const ProcessorBackend = struct {
                fn process(frame: TestMic.Frame, out: []i16) Error!usize {
                    const n = @min(frame.mic[0].len, out.len);
                    @memcpy(out[0..n], frame.mic[0][0..n]);
                    return n;
                }
            };

            const Built = comptime blk: {
                var builder = Builder(grt).init();
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
            var system = try Built.init(alloc, .{});
            defer system.deinit();
            try system.setMic(TestMic.init(&mic_ctx, &MicBackend.vtable));

            try system.start();
            defer system.stop() catch {};

            var out: [8]i16 = @splat(0);
            const n = try pollReadSamples(&system, out[0..], test_async_wait);
            try grt.std.testing.expect(n > 0);
            try grt.std.testing.expect(out[0] != 0);
        }

        fn startAllowsSpeakerOnlyMode(alloc: glib.std.mem.Allocator) !void {
            const Thread = grt.std.Thread;
            const TestSpeaker = SpeakerMod.make(grt, 4);
            const TestMic = MicMod.make(grt, 1, 4);
            const ProcessorBackend = struct {
                fn process(frame: TestMic.Frame, out: []i16) Error!usize {
                    const n = @min(frame.mic[0].len, out.len);
                    @memcpy(out[0..n], frame.mic[0][0..n]);
                    return n;
                }
            };

            const Built = comptime blk: {
                var builder = Builder(grt).init();
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
            var system = try Built.init(alloc, .{});
            defer system.deinit();
            try system.setSpeaker(TestSpeaker.init(&speaker_ctx, &SpeakerBackend.vtable));

            const handle = try system.createTrack(.{});
            defer handle.track.deinit();
            defer handle.ctrl.deinit();
            try handle.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 1, 2, 3, 4 });

            try system.start();
            defer system.stop() catch {};

            var out: [4]i16 = @splat(0);
            try grt.std.testing.expectError(error.InvalidState, system.read(out[0..]));

            const deadline = glib.time.instant.add(grt.time.instant.now(), test_async_wait);
            try grt.std.testing.expect(waitSpeakerWrites(&speaker_ctx, deadline));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("gain_table_func_applies_through_audio_system", glib.testing.TestRunner.fromFn(grt.std, 256 * 1024, struct {
                fn run(_: *glib.testing.T, case_allocator: glib.std.mem.Allocator) !void {
                    try TestCase.gainTableFuncAppliesThroughAudioSystem(case_allocator);
                }
            }.run));
            if (!t.wait()) return false;
            t.run("start_failure_resets_state", glib.testing.TestRunner.fromFn(grt.std, 256 * 1024, struct {
                fn run(_: *glib.testing.T, case_allocator: glib.std.mem.Allocator) !void {
                    try TestCase.startFailureResetsState(case_allocator);
                }
            }.run));
            if (!t.wait()) return false;
            t.run("readLoop_buffers_processed_audio", glib.testing.TestRunner.fromFn(grt.std, 256 * 1024, struct {
                fn run(_: *glib.testing.T, case_allocator: glib.std.mem.Allocator) !void {
                    try TestCase.readLoopBuffersProcessedAudio(case_allocator);
                }
            }.run));
            if (!t.wait()) return false;
            t.run("slow_processor_does_not_block_mic_reads", glib.testing.TestRunner.fromFn(grt.std, 256 * 1024, struct {
                fn run(_: *glib.testing.T, case_allocator: glib.std.mem.Allocator) !void {
                    try TestCase.slowProcessorDoesNotBlockMicReads(case_allocator);
                }
            }.run));
            if (!t.wait()) return false;
            t.run("read_returns_wouldblock_when_running_and_empty", glib.testing.TestRunner.fromFn(grt.std, 256 * 1024, struct {
                fn run(_: *glib.testing.T, case_allocator: glib.std.mem.Allocator) !void {
                    try TestCase.readReturnsWouldBlockWhenRunningAndEmpty(case_allocator);
                }
            }.run));
            if (!t.wait()) return false;
            t.run("readLoop_resets_missing_mic_ref", glib.testing.TestRunner.fromFn(grt.std, 256 * 1024, struct {
                fn run(_: *glib.testing.T, case_allocator: glib.std.mem.Allocator) !void {
                    try TestCase.readLoopResetsMissingMicRef(case_allocator);
                }
            }.run));
            if (!t.wait()) return false;
            t.run("start_allows_mic_only_mode", glib.testing.TestRunner.fromFn(grt.std, 256 * 1024, struct {
                fn run(_: *glib.testing.T, case_allocator: glib.std.mem.Allocator) !void {
                    try TestCase.startAllowsMicOnlyMode(case_allocator);
                }
            }.run));
            if (!t.wait()) return false;
            t.run("start_allows_speaker_only_mode", glib.testing.TestRunner.fromFn(grt.std, 256 * 1024, struct {
                fn run(_: *glib.testing.T, case_allocator: glib.std.mem.Allocator) !void {
                    try TestCase.startAllowsSpeakerOnlyMode(case_allocator);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
