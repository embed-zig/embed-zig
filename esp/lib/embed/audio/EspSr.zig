const embed = @import("embed_core");
const EspAudio = @import("../audio.zig");
const native = @import("esp_sr_binding.zig");

pub const Config = struct {
    sample_rate_hz: u32,
    mic_count: usize,
    ref_count: usize = 1,
    options: Options = .{},
};

pub const PassThroughConfig = struct {
    mic_count: usize,
    options: Options = .{},
};

pub const Options = struct {
    enable_aec: bool = true,
    monitor_gain: i32 = 1,
    aec_mode: AecMode = .full_duplex_low_cost,
    aec_filter_length: i32 = 4,
    aec_nlp_level: AecNlpLevel = .normal,
    aec_linear_only: bool = false,
};

pub const AecMode = enum(i32) {
    speech_recognition_low_cost = 0,
    speech_recognition_high_perf = 1,
    voice_communication_low_cost = 3,
    voice_communication_high_perf = 4,
    full_duplex_low_cost = 5,
    full_duplex_high_perf = 6,
};

pub const AecNlpLevel = enum(i32) {
    normal = 0,
    aggressive = 1,
    very_aggressive = 2,
};

pub fn Processor(comptime Mic: type, comptime config: Config) type {
    if (config.sample_rate_hz == 0) {
        @compileError("EspSr requires non-zero sample_rate_hz");
    }
    if (config.mic_count == 0 or config.mic_count > 2) {
        @compileError("EspSr supports one or two mic channels");
    }
    if (config.ref_count != 1) {
        @compileError("EspSr requires one ref channel");
    }

    return struct {
        pub fn init() embed.audio.AudioSystem.Error!void {
            const native_config = native.Config{
                .sample_rate_hz = config.sample_rate_hz,
                .audio_frame_samples = Mic.frame_samples_per_channel,
                .mic_count = 1,
                .ref_count = config.ref_count,
                .enable_aec = @intFromBool(config.options.enable_aec),
                .aec_mode = @intFromEnum(config.options.aec_mode),
                .aec_filter_length = config.options.aec_filter_length,
                .aec_nlp_level = @intFromEnum(config.options.aec_nlp_level),
                .aec_linear_only = @intFromBool(config.options.aec_linear_only),
            };
            try check("espz_esp_sr_afe_configure", native.espz_esp_sr_afe_configure(&native_config));
            try check("espz_esp_sr_afe_init", native.espz_esp_sr_afe_init());
        }

        pub fn deinit() void {
            native.espz_esp_sr_afe_deinit();
        }

        pub fn reset() embed.audio.AudioSystem.Error!void {
            try check("espz_esp_sr_afe_reset", native.espz_esp_sr_afe_reset());
        }

        pub fn process(frame: Mic.Frame, out: []i16) embed.audio.AudioSystem.Error!usize {
            const raw_ref = frame.ref orelse return error.InvalidState;
            var out_count: usize = 0;
            if (config.mic_count > 1) {
                var mixed: [frame.mic[0].len]i16 = undefined;
                mixMics(mixed[0..], frame.mic[0][0..], frame.mic[1][0..]);
                try processNative(mixed[0..].ptr, raw_ref[0..].ptr, mixed.len, out, &out_count);
            } else {
                try processNative(frame.mic[0][0..].ptr, raw_ref[0..].ptr, frame.mic[0].len, out, &out_count);
            }
            if (config.options.monitor_gain != 1) {
                EspAudio.applyLinearGainSaturating(out[0..out_count], config.options.monitor_gain);
            }
            return out_count;
        }

        fn processNative(
            mic: [*]const i16,
            ref: [*]const i16,
            sample_count: usize,
            out: []i16,
            out_count: *usize,
        ) embed.audio.AudioSystem.Error!void {
            try check(
                "espz_esp_sr_afe_process_i16",
                native.espz_esp_sr_afe_process_i16(
                    mic,
                    ref,
                    sample_count,
                    out.ptr,
                    out.len,
                    out_count,
                ),
            );
        }

        fn mixMics(out: []i16, mic0: []const i16, mic1: []const i16) void {
            for (out, mic0, mic1) |*dst, a, b| {
                dst.* = averageSamples(a, b);
            }
        }

        fn averageSamples(a: i16, b: i16) i16 {
            const sum = @as(i32, a) + @as(i32, b);
            return @intCast(@divTrunc(sum, 2));
        }

        fn check(name: []const u8, rc: c_int) embed.audio.AudioSystem.Error!void {
            if (rc == native.esp_ok) return;
            _ = name;
            return error.Unexpected;
        }
    };
}

pub fn PassThroughProcessor(comptime Mic: type, comptime config: PassThroughConfig) type {
    if (config.mic_count == 0 or config.mic_count > 2) {
        @compileError("EspSr pass-through supports one or two mic channels");
    }

    return struct {
        pub fn init() embed.audio.AudioSystem.Error!void {}

        pub fn deinit() void {}

        pub fn reset() embed.audio.AudioSystem.Error!void {}

        pub fn process(frame: Mic.Frame, out: []i16) embed.audio.AudioSystem.Error!usize {
            if (out.len < frame.mic[0].len) return error.Overflow;
            if (config.mic_count > 1) {
                mixMics(out[0..frame.mic[0].len], frame.mic[0][0..], frame.mic[1][0..]);
            } else {
                @memcpy(out[0..frame.mic[0].len], frame.mic[0][0..]);
            }
            if (config.options.monitor_gain != 1) {
                EspAudio.applyLinearGainSaturating(out[0..frame.mic[0].len], config.options.monitor_gain);
            }
            return frame.mic[0].len;
        }

        fn mixMics(out: []i16, mic0: []const i16, mic1: []const i16) void {
            for (out, mic0, mic1) |*dst, a, b| {
                dst.* = averageSamples(a, b);
            }
        }

        fn averageSamples(a: i16, b: i16) i16 {
            const sum = @as(i32, a) + @as(i32, b);
            return @intCast(@divTrunc(sum, 2));
        }
    };
}
