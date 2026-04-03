const binding = @import("binding.zig");
const EchoState = @import("EchoState.zig");
const error_mod = @import("error.zig");
const types = @import("types.zig");

const Self = @This();
const ValidationError = error{InvalidArgument};
const ControlError = ValidationError || error_mod.ControlError;

state: *binding.SpeexPreprocessState,
frame_size: usize,
sampling_rate: types.SampleRate,

pub fn init(frame_size: usize, sampling_rate: types.SampleRate) error_mod.InitError!Self {
    if (frame_size == 0 or sampling_rate == 0) return error.InvalidArgument;
    if (!fitsCInt(frame_size) or !fitsCInt(sampling_rate)) return error.InvalidArgument;

    const state = binding.speex_preprocess_state_init(
        @intCast(frame_size),
        @intCast(sampling_rate),
    ) orelse return error.OutOfMemory;

    return .{
        .state = state,
        .frame_size = frame_size,
        .sampling_rate = sampling_rate,
    };
}

pub fn deinit(self: *Self) void {
    binding.speex_preprocess_state_destroy(self.state);
    self.* = undefined;
}

pub fn run(self: Self, frame: []types.Sample) ValidationError!bool {
    try validateFrame(self.frame_size, frame.len);
    return binding.speex_preprocess_run(self.state, frame.ptr) != 0;
}

pub fn estimateUpdate(self: Self, frame: []types.Sample) ValidationError!void {
    try validateFrame(self.frame_size, frame.len);
    binding.speex_preprocess_estimate_update(self.state, frame.ptr);
}

pub fn setDenoise(self: Self, enabled: bool) error_mod.ControlError!void {
    var value: c_int = @intFromBool(enabled);
    try error_mod.fromCtlStatus(binding.speex_preprocess_ctl(self.state, binding.SPEEX_PREPROCESS_SET_DENOISE, @ptrCast(&value)));
}

pub fn setAgc(self: Self, enabled: bool) error_mod.ControlError!void {
    var value: c_int = @intFromBool(enabled);
    try error_mod.fromCtlStatus(binding.speex_preprocess_ctl(self.state, binding.SPEEX_PREPROCESS_SET_AGC, @ptrCast(&value)));
}

pub fn setVad(self: Self, enabled: bool) error_mod.ControlError!void {
    var value: c_int = @intFromBool(enabled);
    try error_mod.fromCtlStatus(binding.speex_preprocess_ctl(self.state, binding.SPEEX_PREPROCESS_SET_VAD, @ptrCast(&value)));
}

pub fn setNoiseSuppress(self: Self, db: c_int) error_mod.ControlError!void {
    var value = db;
    try error_mod.fromCtlStatus(binding.speex_preprocess_ctl(self.state, binding.SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, @ptrCast(&value)));
}

pub fn setEchoSuppress(self: Self, db: c_int) error_mod.ControlError!void {
    var value = db;
    try error_mod.fromCtlStatus(binding.speex_preprocess_ctl(self.state, binding.SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, @ptrCast(&value)));
}

pub fn setEchoSuppressActive(self: Self, db: c_int) error_mod.ControlError!void {
    var value = db;
    try error_mod.fromCtlStatus(binding.speex_preprocess_ctl(self.state, binding.SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, @ptrCast(&value)));
}

// The linked echo state is borrowed. Keep the echo state alive for as long as
// this preprocess state may still run against it, and call `clearEchoState()`
// before tearing the echo down if the preprocess state will remain in use.
//
// The caller is also responsible for pairing compatible DSP state, including
// matching frame sizing and sampling-rate configuration across preprocess and
// echo processing.
pub fn setEchoState(self: Self, echo: *EchoState) error_mod.ControlError!void {
    try error_mod.fromCtlStatus(binding.speex_preprocess_ctl(
        self.state,
        binding.SPEEX_PREPROCESS_SET_ECHO_STATE,
        @ptrCast(echo.raw()),
    ));
}

pub fn clearEchoState(self: Self) error_mod.ControlError!void {
    try error_mod.fromCtlStatus(binding.speex_preprocess_ctl(
        self.state,
        binding.SPEEX_PREPROCESS_SET_ECHO_STATE,
        null,
    ));
}

pub fn frameSize(self: Self) usize {
    return self.frame_size;
}

pub fn sampleRate(self: Self) types.SampleRate {
    return self.sampling_rate;
}

pub fn raw(self: Self) *binding.SpeexPreprocessState {
    return self.state;
}

fn validateFrame(expected: usize, actual: usize) ValidationError!void {
    if (actual != expected) return error.InvalidArgument;
}

fn fitsCInt(value: anytype) bool {
    const max = (@as(u64, 1) << (@bitSizeOf(c_int) - 1)) - 1;
    return @as(u64, @intCast(value)) <= max;
}

test "speexdsp/unit_tests/preprocess_state/rejects_invalid_init_arguments" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expectError(error.InvalidArgument, Self.init(0, 16_000));
    try testing.expectError(error.InvalidArgument, Self.init(160, 0));
}

test "speexdsp/unit_tests/preprocess_state/rejects_invalid_frame_lengths" {
    const std = @import("std");
    const testing = std.testing;

    var preprocess = try Self.init(160, 16_000);
    defer preprocess.deinit();

    var frame = [_]types.Sample{0} ** 160;

    try testing.expectError(error.InvalidArgument, preprocess.run(frame[0..159]));
    try testing.expectError(error.InvalidArgument, preprocess.estimateUpdate(frame[0..159]));
}
