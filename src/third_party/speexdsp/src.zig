//! Zig bindings for libspeexdsp.
//!
//! SpeexDSP provides audio processing: acoustic echo cancellation (AEC),
//! noise suppression, automatic gain control, voice activity detection,
//! resampling, jitter buffering, and ring buffering.

const std = @import("std");
const c = @cImport({
    @cInclude("speex/speex_echo.h");
    @cInclude("speex/speex_preprocess.h");
    @cInclude("speex/speex_resampler.h");
    @cInclude("speex/speex_jitter.h");
    @cInclude("speex/speex_buffer.h");
});

// ── Echo Canceller ────────────────────────────────────────────────────────

pub const EchoCanceller = struct {
    handle: *c.SpeexEchoState,
    frame_size: u32,

    pub fn init(frame_size: c_int, filter_length: c_int) ?EchoCanceller {
        return .{
            .handle = c.speex_echo_state_init(frame_size, filter_length) orelse return null,
            .frame_size = @intCast(frame_size),
        };
    }

    pub fn initMc(frame_size: c_int, filter_length: c_int, nb_mic: c_int, nb_speakers: c_int) ?EchoCanceller {
        return .{
            .handle = c.speex_echo_state_init_mc(frame_size, filter_length, nb_mic, nb_speakers) orelse return null,
            .frame_size = @intCast(frame_size),
        };
    }

    pub fn deinit(self: *EchoCanceller) void {
        c.speex_echo_state_destroy(self.handle);
        self.* = undefined;
    }

    pub fn cancel(self: *EchoCanceller, rec: []const i16, play: []const i16, out: []i16) void {
        std.debug.assert(rec.len >= self.frame_size);
        std.debug.assert(play.len >= self.frame_size);
        std.debug.assert(out.len >= self.frame_size);
        c.speex_echo_cancellation(self.handle, rec.ptr, play.ptr, out.ptr);
    }

    pub fn capture(self: *EchoCanceller, rec: []const i16, out: []i16) void {
        std.debug.assert(rec.len >= self.frame_size);
        std.debug.assert(out.len >= self.frame_size);
        c.speex_echo_capture(self.handle, rec.ptr, out.ptr);
    }

    pub fn playback(self: *EchoCanceller, play: []const i16) void {
        std.debug.assert(play.len >= self.frame_size);
        c.speex_echo_playback(self.handle, play.ptr);
    }

    pub fn reset(self: *EchoCanceller) void {
        c.speex_echo_state_reset(self.handle);
    }

    pub fn setSamplingRate(self: *EchoCanceller, rate: i32) void {
        var r = rate;
        _ = c.speex_echo_ctl(self.handle, c.SPEEX_ECHO_SET_SAMPLING_RATE, @ptrCast(&r));
    }

    pub fn getSamplingRate(self: *EchoCanceller) i32 {
        var rate: i32 = 0;
        _ = c.speex_echo_ctl(self.handle, c.SPEEX_ECHO_GET_SAMPLING_RATE, @ptrCast(&rate));
        return rate;
    }
};

// ── Decorrelator ──────────────────────────────────────────────────────────

pub const Decorrelator = struct {
    handle: *c.SpeexDecorrState,

    pub fn init(rate: c_int, channels: c_int, frame_size: c_int) ?Decorrelator {
        return .{
            .handle = c.speex_decorrelate_new(rate, channels, frame_size) orelse return null,
        };
    }

    pub fn deinit(self: *Decorrelator) void {
        c.speex_decorrelate_destroy(self.handle);
        self.* = undefined;
    }

    pub fn process(self: *Decorrelator, in: [*]const i16, out: [*]i16, strength: c_int) void {
        c.speex_decorrelate(self.handle, in, out, strength);
    }
};

// ── Preprocessor ──────────────────────────────────────────────────────────

pub const Preprocessor = struct {
    handle: *c.SpeexPreprocessState,

    pub fn init(frame_size: c_int, sample_rate: c_int) ?Preprocessor {
        return .{
            .handle = c.speex_preprocess_state_init(frame_size, sample_rate) orelse return null,
        };
    }

    pub fn deinit(self: *Preprocessor) void {
        c.speex_preprocess_state_destroy(self.handle);
        self.* = undefined;
    }

    /// Process a frame in-place. Returns true if voice detected (when VAD enabled).
    pub fn run(self: *Preprocessor, audio: [*]i16) bool {
        return c.speex_preprocess_run(self.handle, audio) != 0;
    }

    pub fn estimateUpdate(self: *Preprocessor, audio: [*]i16) void {
        c.speex_preprocess_estimate_update(self.handle, audio);
    }

    pub fn setDenoise(self: *Preprocessor, enable: bool) void {
        self.ctlSetInt(c.SPEEX_PREPROCESS_SET_DENOISE, @intFromBool(enable));
    }

    pub fn setNoiseSuppress(self: *Preprocessor, db: i32) void {
        self.ctlSetInt(c.SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, db);
    }

    pub fn setAgc(self: *Preprocessor, enable: bool) void {
        self.ctlSetInt(c.SPEEX_PREPROCESS_SET_AGC, @intFromBool(enable));
    }

    pub fn setAgcLevel(self: *Preprocessor, level: f32) void {
        var val = level;
        _ = c.speex_preprocess_ctl(self.handle, c.SPEEX_PREPROCESS_SET_AGC_LEVEL, @ptrCast(&val));
    }

    pub fn setAgcTarget(self: *Preprocessor, target: i32) void {
        self.ctlSetInt(c.SPEEX_PREPROCESS_SET_AGC_TARGET, target);
    }

    pub fn setAgcMaxGain(self: *Preprocessor, db: i32) void {
        self.ctlSetInt(c.SPEEX_PREPROCESS_SET_AGC_MAX_GAIN, db);
    }

    pub fn setVad(self: *Preprocessor, enable: bool) void {
        self.ctlSetInt(c.SPEEX_PREPROCESS_SET_VAD, @intFromBool(enable));
    }

    pub fn setProbStart(self: *Preprocessor, prob: i32) void {
        self.ctlSetInt(c.SPEEX_PREPROCESS_SET_PROB_START, prob);
    }

    pub fn setProbContinue(self: *Preprocessor, prob: i32) void {
        self.ctlSetInt(c.SPEEX_PREPROCESS_SET_PROB_CONTINUE, prob);
    }

    pub fn setDereverb(self: *Preprocessor, enable: bool) void {
        self.ctlSetInt(c.SPEEX_PREPROCESS_SET_DEREVERB, @intFromBool(enable));
    }

    pub fn setEchoSuppress(self: *Preprocessor, db: i32) void {
        self.ctlSetInt(c.SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, db);
    }

    pub fn setEchoSuppressActive(self: *Preprocessor, db: i32) void {
        self.ctlSetInt(c.SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, db);
    }

    pub fn setEchoState(self: *Preprocessor, echo: *EchoCanceller) void {
        _ = c.speex_preprocess_ctl(
            self.handle,
            c.SPEEX_PREPROCESS_SET_ECHO_STATE,
            @ptrCast(echo.handle),
        );
    }

    pub fn clearEchoState(self: *Preprocessor) void {
        _ = c.speex_preprocess_ctl(
            self.handle,
            c.SPEEX_PREPROCESS_SET_ECHO_STATE,
            null,
        );
    }

    fn ctlSetInt(self: *Preprocessor, request: c_int, value: i32) void {
        var val = value;
        _ = c.speex_preprocess_ctl(self.handle, request, @ptrCast(&val));
    }
};

// ── Resampler ─────────────────────────────────────────────────────────────

pub const ResamplerError = error{
    AllocFailed,
    BadState,
    InvalidArg,
    PtrOverlap,
    Overflow,
    Unknown,
};

fn checkResamplerError(err: c_int) ResamplerError!void {
    return switch (err) {
        c.RESAMPLER_ERR_SUCCESS => {},
        c.RESAMPLER_ERR_ALLOC_FAILED => ResamplerError.AllocFailed,
        c.RESAMPLER_ERR_BAD_STATE => ResamplerError.BadState,
        c.RESAMPLER_ERR_INVALID_ARG => ResamplerError.InvalidArg,
        c.RESAMPLER_ERR_PTR_OVERLAP => ResamplerError.PtrOverlap,
        c.RESAMPLER_ERR_OVERFLOW => ResamplerError.Overflow,
        else => ResamplerError.Unknown,
    };
}

pub const ProcessResult = struct {
    in_consumed: u32,
    out_written: u32,
};

pub const Resampler = struct {
    handle: *c.SpeexResamplerState,

    pub fn init(nb_channels: u32, in_rate: u32, out_rate: u32, quality: c_int) ResamplerError!Resampler {
        var err: c_int = 0;
        const handle = c.speex_resampler_init(
            nb_channels,
            in_rate,
            out_rate,
            quality,
            &err,
        ) orelse return ResamplerError.AllocFailed;
        try checkResamplerError(err);
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Resampler) void {
        c.speex_resampler_destroy(self.handle);
        self.* = undefined;
    }

    pub fn processInt(self: *Resampler, channel: u32, in_buf: []const i16, out_buf: []i16) ResamplerError!ProcessResult {
        var in_len: u32 = @intCast(in_buf.len);
        var out_len: u32 = @intCast(out_buf.len);
        try checkResamplerError(c.speex_resampler_process_int(
            self.handle,
            channel,
            in_buf.ptr,
            &in_len,
            out_buf.ptr,
            &out_len,
        ));
        return .{ .in_consumed = in_len, .out_written = out_len };
    }

    pub fn processFloat(self: *Resampler, channel: u32, in_buf: []const f32, out_buf: []f32) ResamplerError!ProcessResult {
        var in_len: u32 = @intCast(in_buf.len);
        var out_len: u32 = @intCast(out_buf.len);
        try checkResamplerError(c.speex_resampler_process_float(
            self.handle,
            channel,
            in_buf.ptr,
            &in_len,
            out_buf.ptr,
            &out_len,
        ));
        return .{ .in_consumed = in_len, .out_written = out_len };
    }

    pub fn processInterleavedInt(self: *Resampler, in_buf: []const i16, out_buf: []i16) ResamplerError!ProcessResult {
        var in_len: u32 = @intCast(in_buf.len);
        var out_len: u32 = @intCast(out_buf.len);
        try checkResamplerError(c.speex_resampler_process_interleaved_int(
            self.handle,
            in_buf.ptr,
            &in_len,
            out_buf.ptr,
            &out_len,
        ));
        return .{ .in_consumed = in_len, .out_written = out_len };
    }

    pub fn processInterleavedFloat(self: *Resampler, in_buf: []const f32, out_buf: []f32) ResamplerError!ProcessResult {
        var in_len: u32 = @intCast(in_buf.len);
        var out_len: u32 = @intCast(out_buf.len);
        try checkResamplerError(c.speex_resampler_process_interleaved_float(
            self.handle,
            in_buf.ptr,
            &in_len,
            out_buf.ptr,
            &out_len,
        ));
        return .{ .in_consumed = in_len, .out_written = out_len };
    }

    pub fn setRate(self: *Resampler, in_rate: u32, out_rate: u32) ResamplerError!void {
        try checkResamplerError(c.speex_resampler_set_rate(self.handle, in_rate, out_rate));
    }

    pub fn getRate(self: *Resampler) struct { in_rate: u32, out_rate: u32 } {
        var in_rate: u32 = 0;
        var out_rate: u32 = 0;
        c.speex_resampler_get_rate(self.handle, &in_rate, &out_rate);
        return .{ .in_rate = in_rate, .out_rate = out_rate };
    }

    pub fn setQuality(self: *Resampler, quality: c_int) ResamplerError!void {
        try checkResamplerError(c.speex_resampler_set_quality(self.handle, quality));
    }

    pub fn getQuality(self: *Resampler) c_int {
        var quality: c_int = 0;
        c.speex_resampler_get_quality(self.handle, &quality);
        return quality;
    }

    pub fn getInputLatency(self: *Resampler) c_int {
        return c.speex_resampler_get_input_latency(self.handle);
    }

    pub fn getOutputLatency(self: *Resampler) c_int {
        return c.speex_resampler_get_output_latency(self.handle);
    }

    pub fn skipZeros(self: *Resampler) ResamplerError!void {
        try checkResamplerError(c.speex_resampler_skip_zeros(self.handle));
    }

    pub fn reset(self: *Resampler) ResamplerError!void {
        try checkResamplerError(c.speex_resampler_reset_mem(self.handle));
    }

    pub fn strerror(err_code: c_int) [*:0]const u8 {
        return c.speex_resampler_strerror(err_code);
    }
};

// ── Jitter Buffer ─────────────────────────────────────────────────────────

pub const JitterBuffer = struct {
    handle: *c.JitterBuffer,

    pub const Packet = c.JitterBufferPacket;

    pub const GetStatus = enum(c_int) {
        ok = c.JITTER_BUFFER_OK,
        missing = c.JITTER_BUFFER_MISSING,
        insertion = c.JITTER_BUFFER_INSERTION,
    };

    pub fn init(step_size: c_int) ?JitterBuffer {
        return .{
            .handle = c.jitter_buffer_init(step_size) orelse return null,
        };
    }

    pub fn deinit(self: *JitterBuffer) void {
        c.jitter_buffer_destroy(self.handle);
        self.* = undefined;
    }

    pub fn put(self: *JitterBuffer, packet: *const Packet) void {
        c.jitter_buffer_put(self.handle, packet);
    }

    pub fn get(self: *JitterBuffer, packet: *Packet, desired_span: i32, offset: *i32) ?GetStatus {
        const ret = c.jitter_buffer_get(self.handle, packet, desired_span, offset);
        return std.meta.intToEnum(GetStatus, ret) catch null;
    }

    pub fn tick(self: *JitterBuffer) void {
        c.jitter_buffer_tick(self.handle);
    }

    pub fn reset(self: *JitterBuffer) void {
        c.jitter_buffer_reset(self.handle);
    }

    pub fn remainingSpan(self: *JitterBuffer, rem: u32) void {
        c.jitter_buffer_remaining_span(self.handle, rem);
    }

    pub fn getPointerTimestamp(self: *JitterBuffer) c_int {
        return c.jitter_buffer_get_pointer_timestamp(self.handle);
    }
};

// ── Ring Buffer ───────────────────────────────────────────────────────────

pub const Buffer = struct {
    handle: *c.SpeexBuffer,

    pub fn init(size: c_int) ?Buffer {
        return .{
            .handle = c.speex_buffer_init(size) orelse return null,
        };
    }

    pub fn deinit(self: *Buffer) void {
        c.speex_buffer_destroy(self.handle);
        self.* = undefined;
    }

    pub fn write(self: *Buffer, data: []const u8) c_int {
        return c.speex_buffer_write(self.handle, @ptrCast(@constCast(data.ptr)), @intCast(data.len));
    }

    pub fn read(self: *Buffer, data: []u8) c_int {
        return c.speex_buffer_read(self.handle, @ptrCast(data.ptr), @intCast(data.len));
    }

    pub fn writeZeros(self: *Buffer, len: c_int) c_int {
        return c.speex_buffer_writezeros(self.handle, len);
    }

    pub fn getAvailable(self: *Buffer) c_int {
        return c.speex_buffer_get_available(self.handle);
    }

    pub fn resize(self: *Buffer, len: c_int) c_int {
        return c.speex_buffer_resize(self.handle, len);
    }
};

// ── tests ─────────────────────────────────────────────────────────────────

test "echo canceller lifecycle" {
    var aec = EchoCanceller.init(160, 1024) orelse return error.InitFailed;
    defer aec.deinit();

    aec.setSamplingRate(16000);
    try std.testing.expectEqual(@as(i32, 16000), aec.getSamplingRate());

    aec.reset();
}

test "echo canceller cancel zero frame" {
    var aec = EchoCanceller.init(160, 1024) orelse return error.InitFailed;
    defer aec.deinit();
    aec.setSamplingRate(16000);

    var rec = [_]i16{0} ** 160;
    var play = [_]i16{0} ** 160;
    var out = [_]i16{0} ** 160;

    aec.cancel(&rec, &play, &out);
}

test "preprocessor lifecycle" {
    var pp = Preprocessor.init(160, 16000) orelse return error.InitFailed;
    defer pp.deinit();

    pp.setDenoise(true);
    pp.setNoiseSuppress(-20);
    pp.setAgc(true);
    pp.setAgcLevel(8000);
    pp.setVad(true);
    pp.setDereverb(false);
}

test "preprocessor run zero frame" {
    var pp = Preprocessor.init(160, 16000) orelse return error.InitFailed;
    defer pp.deinit();

    var audio = [_]i16{0} ** 160;
    _ = pp.run(&audio);
}

test "preprocessor linked to echo canceller" {
    var aec = EchoCanceller.init(160, 1024) orelse return error.InitFailed;
    defer aec.deinit();
    aec.setSamplingRate(16000);

    var pp = Preprocessor.init(160, 16000) orelse return error.InitFailed;
    defer pp.deinit();
    pp.setEchoState(&aec);

    var audio = [_]i16{0} ** 160;
    _ = pp.run(&audio);

    pp.clearEchoState();
}

test "resampler lifecycle" {
    var rs = try Resampler.init(1, 48000, 16000, 5);
    defer rs.deinit();

    const rate = rs.getRate();
    try std.testing.expectEqual(@as(u32, 48000), rate.in_rate);
    try std.testing.expectEqual(@as(u32, 16000), rate.out_rate);

    try std.testing.expectEqual(@as(c_int, 5), rs.getQuality());
    try std.testing.expect(rs.getInputLatency() >= 0);
    try std.testing.expect(rs.getOutputLatency() >= 0);
}

test "resampler 48k to 16k" {
    var rs = try Resampler.init(1, 48000, 16000, 5);
    defer rs.deinit();

    var input = [_]i16{0} ** 480;
    var output = [_]i16{0} ** 200;
    const result = try rs.processInt(0, &input, &output);

    try std.testing.expectEqual(@as(u32, 480), result.in_consumed);
    try std.testing.expect(result.out_written > 0);
}

test "jitter buffer lifecycle" {
    var jb = JitterBuffer.init(160) orelse return error.InitFailed;
    defer jb.deinit();

    jb.tick();
    jb.reset();
}

test "buffer write and read" {
    var buf = Buffer.init(256) orelse return error.InitFailed;
    defer buf.deinit();

    try std.testing.expectEqual(@as(c_int, 0), buf.getAvailable());

    const data = "hello speexdsp";
    _ = buf.write(data);
    try std.testing.expectEqual(@as(c_int, @intCast(data.len)), buf.getAvailable());

    var out: [32]u8 = undefined;
    const n = buf.read(out[0..data.len]);
    try std.testing.expectEqual(@as(c_int, @intCast(data.len)), n);
    try std.testing.expectEqualSlices(u8, data, out[0..@intCast(n)]);
}

test "buffer write zeros" {
    var buf = Buffer.init(256) orelse return error.InitFailed;
    defer buf.deinit();

    _ = buf.writeZeros(16);
    try std.testing.expectEqual(@as(c_int, 16), buf.getAvailable());
}
