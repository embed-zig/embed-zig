const binding = @import("binding.zig");
const error_mod = @import("error.zig");
const types = @import("types.zig");

const Self = @This();
const ValidationError = error{InvalidArgument};
const OperationError = ValidationError || error_mod.ResamplerError;

state: *binding.SpeexResamplerState,
channels: types.ChannelCount,

pub fn init(
    channels: types.ChannelCount,
    in_rate: types.SampleRate,
    out_rate: types.SampleRate,
    quality: types.Quality,
) (ValidationError || error_mod.InitError)!Self {
    if (channels == 0 or in_rate == 0 or out_rate == 0) return error.InvalidArgument;
    if (!fitsSpxUint32(channels) or !fitsSpxUint32(in_rate) or !fitsSpxUint32(out_rate)) return error.InvalidArgument;
    if (quality < types.resampler_quality_min or quality > types.resampler_quality_max) return error.InvalidArgument;

    var status: c_int = binding.RESAMPLER_ERR_SUCCESS;
    const state = binding.speex_resampler_init(
        @intCast(channels),
        @intCast(in_rate),
        @intCast(out_rate),
        quality,
        &status,
    ) orelse {
        try error_mod.fromResamplerStatusOrInit(status);
        return error.Unexpected;
    };

    return .{
        .state = state,
        .channels = channels,
    };
}

pub fn deinit(self: *Self) void {
    binding.speex_resampler_destroy(self.state);
    self.* = undefined;
}

pub fn processInt(
    self: Self,
    channel_index: types.ChannelCount,
    input: []const types.Sample,
    output: []types.Sample,
) OperationError!types.ProcessResult {
    if (channel_index >= self.channels) return error.InvalidArgument;
    if (!fitsSpxUint32(input.len) or !fitsSpxUint32(output.len)) return error.InvalidArgument;

    var in_len: binding.spx_uint32_t = @intCast(input.len);
    var out_len: binding.spx_uint32_t = @intCast(output.len);
    try error_mod.fromResamplerStatus(binding.speex_resampler_process_int(
        self.state,
        @intCast(channel_index),
        input.ptr,
        &in_len,
        output.ptr,
        &out_len,
    ));
    return .{
        .input_consumed = @intCast(in_len),
        .output_produced = @intCast(out_len),
    };
}

pub fn processInterleavedInt(
    self: Self,
    input: []const types.Sample,
    output: []types.Sample,
) OperationError!types.InterleavedProcessResult {
    if (self.channels == 0) return error.InvalidArgument;
    const channels: usize = @intCast(self.channels);
    if (input.len % channels != 0 or output.len % channels != 0) return error.InvalidArgument;

    const input_frames = input.len / channels;
    const output_frames = output.len / channels;
    if (!fitsSpxUint32(input_frames) or !fitsSpxUint32(output_frames)) return error.InvalidArgument;

    var in_len: binding.spx_uint32_t = @intCast(input_frames);
    var out_len: binding.spx_uint32_t = @intCast(output_frames);
    try error_mod.fromResamplerStatus(binding.speex_resampler_process_interleaved_int(
        self.state,
        input.ptr,
        &in_len,
        output.ptr,
        &out_len,
    ));
    return .{
        .input_frames_consumed = @intCast(in_len),
        .output_frames_produced = @intCast(out_len),
    };
}

pub fn setRate(self: Self, in_rate: types.SampleRate, out_rate: types.SampleRate) OperationError!void {
    if (in_rate == 0 or out_rate == 0) return error.InvalidArgument;
    if (!fitsSpxUint32(in_rate) or !fitsSpxUint32(out_rate)) return error.InvalidArgument;
    try error_mod.fromResamplerStatus(binding.speex_resampler_set_rate(
        self.state,
        @intCast(in_rate),
        @intCast(out_rate),
    ));
}

pub fn getRate(self: Self) struct { in_rate: types.SampleRate, out_rate: types.SampleRate } {
    var in_rate: binding.spx_uint32_t = 0;
    var out_rate: binding.spx_uint32_t = 0;
    binding.speex_resampler_get_rate(self.state, &in_rate, &out_rate);
    return .{
        .in_rate = @intCast(in_rate),
        .out_rate = @intCast(out_rate),
    };
}

pub fn setQuality(self: Self, quality: types.Quality) OperationError!void {
    if (quality < types.resampler_quality_min or quality > types.resampler_quality_max) return error.InvalidArgument;
    try error_mod.fromResamplerStatus(binding.speex_resampler_set_quality(self.state, quality));
}

pub fn getQuality(self: Self) types.Quality {
    var quality: c_int = 0;
    binding.speex_resampler_get_quality(self.state, &quality);
    return quality;
}

pub fn inputLatency(self: Self) u32 {
    const latency = binding.speex_resampler_get_input_latency(self.state);
    return if (latency < 0) 0 else @intCast(latency);
}

pub fn outputLatency(self: Self) u32 {
    const latency = binding.speex_resampler_get_output_latency(self.state);
    return if (latency < 0) 0 else @intCast(latency);
}

pub fn skipZeros(self: Self) error_mod.ResamplerError!void {
    try error_mod.fromResamplerStatus(binding.speex_resampler_skip_zeros(self.state));
}

pub fn reset(self: Self) error_mod.ResamplerError!void {
    try error_mod.fromResamplerStatus(binding.speex_resampler_reset_mem(self.state));
}

pub fn channelCount(self: Self) types.ChannelCount {
    return self.channels;
}

pub fn raw(self: Self) *binding.SpeexResamplerState {
    return self.state;
}

fn fitsSpxUint32(value: anytype) bool {
    const max = (@as(u64, 1) << @bitSizeOf(binding.spx_uint32_t)) - 1;
    return @as(u64, @intCast(value)) <= max;
}

test "speexdsp/unit_tests/resampler/rejects_invalid_init_arguments" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expectError(error.InvalidArgument, Self.init(0, 16_000, 16_000, types.resampler_quality_default));
    try testing.expectError(error.InvalidArgument, Self.init(1, 0, 16_000, types.resampler_quality_default));
    try testing.expectError(error.InvalidArgument, Self.init(1, 16_000, 16_000, types.resampler_quality_max + 1));
}

test "speexdsp/unit_tests/resampler/rejects_invalid_process_arguments" {
    const std = @import("std");
    const testing = std.testing;

    var resampler = try Self.init(2, 16_000, 8_000, types.resampler_quality_default);
    defer resampler.deinit();

    var mono_in = [_]types.Sample{0} ** 160;
    var mono_out = [_]types.Sample{0} ** 160;
    var interleaved_in = [_]types.Sample{0} ** 321;
    var interleaved_out = [_]types.Sample{0} ** 320;

    try testing.expectError(error.InvalidArgument, resampler.processInt(2, mono_in[0..], mono_out[0..]));
    try testing.expectError(error.InvalidArgument, resampler.processInterleavedInt(interleaved_in[0..], interleaved_out[0..]));
}

test "speexdsp/unit_tests/resampler/rejects_invalid_control_arguments" {
    const std = @import("std");
    const testing = std.testing;

    var resampler = try Self.init(1, 16_000, 8_000, types.resampler_quality_default);
    defer resampler.deinit();

    try testing.expectError(error.InvalidArgument, resampler.setRate(0, 16_000));
    try testing.expectError(error.InvalidArgument, resampler.setRate(16_000, 0));
    try testing.expectError(error.InvalidArgument, resampler.setQuality(types.resampler_quality_min - 1));
    try testing.expectError(error.InvalidArgument, resampler.setQuality(types.resampler_quality_max + 1));
}
