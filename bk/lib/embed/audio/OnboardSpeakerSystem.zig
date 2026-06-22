const bk = @import("../../bk.zig");
const embed = @import("embed_core");
const glib = @import("glib");
const binding = @import("binding.zig");

pub const AecOptions = struct {
    delay_samples: u32 = 211,
    ec_depth: u32 = 50,
    tx_rx_thr: u32 = 30,
    tx_rx_flr: u32 = 6,
    ref_scale: u8 = 0,
    ns_level: u8 = 2,
    ns_para: u8 = 1,
    voice_volume: u32 = 8,
    drc: u32 = 0x10,
};

pub const Options = struct {
    sample_rate: u32 = 16_000,
    frame_samples_per_channel: usize = 320,
    channels: u8 = 1,
    mic_channels: u8 = 0,
    speaker_channels: u8 = 0,
    bits_per_sample: u8 = 16,
    default_volume: u8 = 0x2d,
    default_mic_gain: u8 = 0x2d,
    frame_count: usize = 8,
    aec: ?AecOptions = .{},
};

pub fn make(comptime options: Options) type {
    if (options.sample_rate == 0) @compileError("OnboardSpeakerSystem requires non-zero sample_rate");
    if (options.frame_samples_per_channel == 0) @compileError("OnboardSpeakerSystem requires non-zero frame_samples_per_channel");
    if (options.channels == 0) @compileError("OnboardSpeakerSystem requires non-zero channels");
    if (options.bits_per_sample != 16) @compileError("OnboardSpeakerSystem currently supports 16-bit PCM only");
    if (options.frame_count < 2) @compileError("OnboardSpeakerSystem requires at least two queued frames");
    const mic_channels = if (options.mic_channels == 0) options.channels else options.mic_channels;
    const speaker_channels = if (options.speaker_channels == 0) options.channels else options.speaker_channels;
    if (mic_channels == 0) @compileError("OnboardSpeakerSystem requires non-zero mic_channels");
    if (speaker_channels == 0) @compileError("OnboardSpeakerSystem requires non-zero speaker_channels");
    if (options.aec != null and speaker_channels != 1) @compileError("OnboardSpeakerSystem AEC currently supports mono speaker only");

    return struct {
        const Self = @This();
        const grt = bk.ap.grt;
        const log = grt.std.log.scoped(.bk_audio_system);

        pub const sample_rate = options.sample_rate;
        pub const mic_count = mic_channels;
        pub const frame_samples_per_channel = options.frame_samples_per_channel;
        pub const Mic = embed.audio.Mic.make(grt, mic_count, frame_samples_per_channel);
        pub const Speaker = embed.audio.Speaker.make(grt, frame_samples_per_channel);
        pub const Type = blk: {
            var builder = embed.audio.AudioSystem.Builder(grt).init();
            builder.configMic(mic_count, frame_samples_per_channel);
            builder.configSpeaker(frame_samples_per_channel);
            builder.setProcessor(&processMic);
            break :blk builder.build();
        };

        allocator: grt.std.mem.Allocator,
        state: *State,
        core: Type,

        pub fn init(allocator: grt.std.mem.Allocator, config: Type.Config) !Self {
            const state = try allocator.create(State);
            errdefer allocator.destroy(state);
            state.* = .{};

            var core = try Type.init(allocator, config);
            errdefer core.deinit();

            try state.ensureSpeakerInitialized();
            try state.ensureMicInitialized();
            try state.ensureAecInitialized();
            try core.setSpeaker(state.speaker());
            try core.setMic(state.mic());

            return .{
                .allocator = allocator,
                .state = state,
                .core = core,
            };
        }

        pub fn deinit(self: *Self) void {
            self.core.deinit();
            self.state.deinit();
            self.allocator.destroy(self.state);
            self.* = undefined;
        }

        pub fn system(self: *Self) *Type {
            return &self.core;
        }

        var aec_probe_count: usize = 0;
        var aec_probe_window: AecProbe = .{};

        fn processMic(frame: Mic.Frame, out: []i16) embed.audio.AudioSystem.Error!usize {
            const n = @min(out.len, frame.mic[0].len);
            if (comptime options.aec != null) {
                if (n != frame_samples_per_channel) return error.Unsupported;
                const ref = frame.ref orelse [_]i16{0} ** frame_samples_per_channel;
                const mic = if (comptime mic_count == 1) frame.mic[0] else downmixMics(frame.mic, n);
                try check("aec process", binding.bk_embed_audio_aec_process(
                    ref[0..n].ptr,
                    mic[0..n].ptr,
                    out[0..n].ptr,
                    n,
                ));
                reportAecProbe(ref[0..n], frame.mic, mic[0..n], out[0..n]);
            } else {
                if (comptime mic_count == 1) {
                    @memcpy(out[0..n], frame.mic[0][0..n]);
                } else {
                    const mic = downmixMics(frame.mic, n);
                    @memcpy(out[0..n], mic[0..n]);
                }
            }
            return n;
        }

        fn downmixMics(mics: [mic_count][frame_samples_per_channel]i16, n: usize) [frame_samples_per_channel]i16 {
            var out: [frame_samples_per_channel]i16 = @splat(0);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var sum: i32 = 0;
                inline for (0..mic_count) |mic_index| {
                    sum += mics[mic_index][i];
                }
                out[i] = @intCast(@divTrunc(sum, @as(i32, @intCast(mic_count))));
            }
            return out;
        }

        fn reportAecProbe(ref: []const i16, mics: [mic_count][frame_samples_per_channel]i16, mic: []const i16, out: []const i16) void {
            aec_probe_count += 1;
            aec_probe_window.add(ref, mics, mic, out);
            if (aec_probe_count <= 5 or aec_probe_count % 250 == 0) {
                log.info(
                    "aec probe count={} frames={} ref_peak={} ref_clip={} mic_peak={} mic_clip={} mic0_peak={} mic0_clip={} mic1_peak={} mic1_clip={} out_peak={} out_clip={}",
                    .{
                        aec_probe_count,
                        aec_probe_window.frames,
                        aec_probe_window.ref_peak,
                        aec_probe_window.ref_clip,
                        aec_probe_window.mic_peak,
                        aec_probe_window.mic_clip,
                        aec_probe_window.mic0_peak,
                        aec_probe_window.mic0_clip,
                        aec_probe_window.mic1_peak,
                        aec_probe_window.mic1_clip,
                        aec_probe_window.out_peak,
                        aec_probe_window.out_clip,
                    },
                );
                aec_probe_window = .{};
            }
        }

        const AecProbe = struct {
            frames: usize = 0,
            ref_peak: u16 = 0,
            ref_clip: usize = 0,
            mic_peak: u16 = 0,
            mic_clip: usize = 0,
            mic0_peak: u16 = 0,
            mic0_clip: usize = 0,
            mic1_peak: u16 = 0,
            mic1_clip: usize = 0,
            out_peak: u16 = 0,
            out_clip: usize = 0,

            fn add(self: *AecProbe, ref: []const i16, mics: [mic_count][frame_samples_per_channel]i16, mic: []const i16, out: []const i16) void {
                self.frames += 1;
                self.addSamples(ref, &self.ref_peak, &self.ref_clip);
                self.addSamples(mic, &self.mic_peak, &self.mic_clip);
                self.addSamples(mics[0][0..mic.len], &self.mic0_peak, &self.mic0_clip);
                if (comptime mic_count > 1) {
                    self.addSamples(mics[1][0..mic.len], &self.mic1_peak, &self.mic1_clip);
                }
                self.addSamples(out, &self.out_peak, &self.out_clip);
            }

            fn addSamples(_: *AecProbe, samples: []const i16, peak: *u16, clips: *usize) void {
                for (samples) |sample| {
                    const value: i32 = sample;
                    const abs: u16 = @intCast(if (value < 0) -value else value);
                    peak.* = @max(peak.*, abs);
                    if (sample >= 32000 or sample <= -32000) clips.* += 1;
                }
            }
        };

        fn clipCount(samples: []const i16) usize {
            var count: usize = 0;
            for (samples) |sample| {
                if (sample >= 32000 or sample <= -32000) count += 1;
            }
            return count;
        }

        const State = struct {
            speaker_initialized: bool = false,
            mic_initialized: bool = false,
            aec_initialized: bool = false,
            speaker_gain_db: ?i8 = null,
            mic_gains_db: Mic.Gains = [_]?i8{null} ** mic_count,

            fn ensureSpeakerInitialized(self: *State) embed.audio.AudioSystem.Error!void {
                if (self.speaker_initialized) return;
                const frame_size = frame_samples_per_channel * @as(usize, speaker_channels) * @as(usize, options.bits_per_sample / 8);
                const pool_size = frame_size * options.frame_count;
                try check("speaker init", binding.bk_embed_audio_onboard_speaker_init(
                    sample_rate,
                    speaker_channels,
                    options.bits_per_sample,
                    options.default_volume,
                    @intCast(frame_size),
                    @intCast(pool_size),
                ));
                self.speaker_initialized = true;
            }

            fn ensureMicInitialized(self: *State) embed.audio.AudioSystem.Error!void {
                if (self.mic_initialized) return;
                const frame_size = frame_samples_per_channel * @as(usize, mic_channels) * @as(usize, options.bits_per_sample / 8);
                const pool_size = frame_size * options.frame_count;
                try check("mic init", binding.bk_embed_audio_onboard_mic_init(
                    sample_rate,
                    mic_channels,
                    options.bits_per_sample,
                    options.default_mic_gain,
                    @intCast(frame_size),
                    @intCast(pool_size),
                ));
                self.mic_initialized = true;
            }

            fn ensureAecInitialized(self: *State) embed.audio.AudioSystem.Error!void {
                if (comptime options.aec == null) return;
                if (self.aec_initialized) return;
                const aec = comptime options.aec.?;
                try check("aec init", binding.bk_embed_audio_aec_init(
                    sample_rate,
                    @intCast(frame_samples_per_channel),
                    aec.delay_samples,
                    aec.ec_depth,
                    aec.tx_rx_thr,
                    aec.tx_rx_flr,
                    aec.ref_scale,
                    aec.ns_level,
                    aec.ns_para,
                    aec.voice_volume,
                    aec.drc,
                ));
                self.aec_initialized = true;
            }

            fn deinit(self: *State) void {
                if (self.aec_initialized) {
                    binding.bk_embed_audio_aec_deinit();
                }
                if (self.mic_initialized) {
                    binding.bk_embed_audio_onboard_mic_deinit();
                }
                if (self.speaker_initialized) {
                    binding.bk_embed_audio_onboard_speaker_deinit();
                }
                self.* = undefined;
            }

            fn speaker(self: *State) Speaker {
                var out = Speaker.init(self, &speaker_vtable);
                out.setGainTableFunc(&logicalDbToBkGain);
                return out;
            }

            fn mic(self: *State) Mic {
                var out = Mic.init(self, &mic_vtable);
                out.setGainTableFunc(&logicalDbToBkGain);
                return out;
            }
        };

        const mic_vtable = Mic.VTable{
            .deinit = micDeinit,
            .sampleRate = micSampleRate,
            .micCount = micCount,
            .read = micRead,
            .gains = micGains,
            .setGains = micSetGains,
            .enable = micEnable,
            .disable = micDisable,
        };

        const speaker_vtable = Speaker.VTable{
            .deinit = speakerDeinit,
            .sampleRate = speakerSampleRate,
            .write = speakerWrite,
            .gain = speakerGain,
            .setGain = speakerSetGain,
            .enable = speakerEnable,
            .disable = speakerDisable,
        };

        fn micDeinit(_: *anyopaque) void {}

        fn micSampleRate(_: *anyopaque) u32 {
            return sample_rate;
        }

        fn micCount(_: *anyopaque) u8 {
            return mic_count;
        }

        fn micRead(_: *anyopaque, frame: *Mic.Frame) embed.audio.AudioSystem.Error!void {
            frame.ref = null;
            var interleaved: [frame_samples_per_channel * mic_count]i16 = undefined;
            const bytes = glib.std.mem.sliceAsBytes(interleaved[0..]);
            const read = binding.bk_embed_audio_onboard_mic_read(bytes.ptr, bytes.len);
            if (read < 0) {
                try check("mic read", read);
            }
            if (@as(usize, @intCast(read)) != bytes.len) {
                log.err("mic short read bytes={d}/{d}", .{ read, bytes.len });
                return error.Unexpected;
            }
            var frame_index: usize = 0;
            while (frame_index < frame_samples_per_channel) : (frame_index += 1) {
                inline for (0..mic_count) |mic_index| {
                    frame.mic[mic_index][frame_index] = interleaved[frame_index * mic_count + mic_index];
                }
            }
        }

        fn micGains(ptr: *anyopaque) Mic.Gains {
            const self: *State = @ptrCast(@alignCast(ptr));
            return self.mic_gains_db;
        }

        fn micSetGains(ptr: *anyopaque, gains_db: []const ?i8) embed.audio.AudioSystem.Error!void {
            if (gains_db.len > mic_count) return error.Unsupported;
            const self: *State = @ptrCast(@alignCast(ptr));
            try self.ensureMicInitialized();
            for (gains_db, 0..) |gain_db, index| {
                if (gain_db) |value| {
                    try check("mic gain", binding.bk_embed_audio_onboard_mic_set_gain(bkGainToVolume(value)));
                    self.mic_gains_db[index] = value;
                }
            }
        }

        fn micEnable(ptr: *anyopaque) embed.audio.AudioSystem.Error!void {
            const self: *State = @ptrCast(@alignCast(ptr));
            try self.ensureMicInitialized();
            try check("mic enable", binding.bk_embed_audio_onboard_mic_enable());
        }

        fn micDisable(_: *anyopaque) embed.audio.AudioSystem.Error!void {
            try check("mic disable", binding.bk_embed_audio_onboard_mic_disable());
        }

        fn speakerDeinit(_: *anyopaque) void {}

        fn speakerSampleRate(_: *anyopaque) u32 {
            return sample_rate;
        }

        fn speakerWrite(_: *anyopaque, frame: []const i16) embed.audio.AudioSystem.Error!usize {
            if (frame.len == 0) return 0;
            const bytes = glib.std.mem.sliceAsBytes(frame);
            const written = binding.bk_embed_audio_onboard_speaker_write(bytes.ptr, bytes.len);
            if (written < 0) {
                try check("speaker write", written);
            }
            if (@as(usize, @intCast(written)) != bytes.len) {
                log.err("speaker short write bytes={d}/{d}", .{ written, bytes.len });
                return error.Unexpected;
            }
            return frame.len;
        }

        fn speakerGain(ptr: *anyopaque) ?i8 {
            const self: *State = @ptrCast(@alignCast(ptr));
            return self.speaker_gain_db;
        }

        fn speakerSetGain(ptr: *anyopaque, gain_db: i8) embed.audio.AudioSystem.Error!void {
            const self: *State = @ptrCast(@alignCast(ptr));
            try self.ensureSpeakerInitialized();
            try check("speaker volume", binding.bk_embed_audio_onboard_speaker_set_volume(bkGainToVolume(gain_db)));
            self.speaker_gain_db = gain_db;
        }

        fn speakerEnable(ptr: *anyopaque) embed.audio.AudioSystem.Error!void {
            const self: *State = @ptrCast(@alignCast(ptr));
            try self.ensureSpeakerInitialized();
            try check("speaker enable", binding.bk_embed_audio_onboard_speaker_enable());
        }

        fn speakerDisable(_: *anyopaque) embed.audio.AudioSystem.Error!void {
            try check("speaker disable", binding.bk_embed_audio_onboard_speaker_disable());
        }

        fn logicalDbToBkGain(gain_db: i8) i8 {
            if (gain_db <= -45) return 0;
            if (gain_db >= 18) return 0x3f;
            return gain_db + 45;
        }

        fn bkGainToVolume(gain: i8) u8 {
            if (gain <= 0) return 0;
            if (gain >= 0x3f) return 0x3f;
            return @intCast(gain);
        }

        fn check(name: []const u8, rc: c_int) embed.audio.AudioSystem.Error!void {
            if (rc == binding.ok) return;
            log.err("{s} failed rc={d}", .{ name, rc });
            return error.Unexpected;
        }
    };
}
