const embed = @import("embed");
const binding = @import("binding.zig");
const opus_error = @import("error.zig");
const types = @import("types.zig");

const Self = @This();

handle: *binding.OpusEncoder,
mem: []align(16) u8,
sample_rate: u32,
channels: u8,

pub const Error = types.Error;
pub const Application = types.Application;
pub const Signal = types.Signal;
pub const Bandwidth = types.Bandwidth;

pub fn getSize(channels: u8) usize {
    return @intCast(binding.opus_encoder_get_size(@intCast(channels)));
}

pub fn init(
    allocator: embed.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    application: Application,
) (Error || embed.mem.Allocator.Error)!Self {
    const size = getSize(channels);
    const mem = try allocator.alignedAlloc(u8, .@"16", size);
    errdefer allocator.free(mem);

    const handle: *binding.OpusEncoder = @ptrCast(mem.ptr);
    try opus_error.checkError(binding.opus_encoder_init(
        handle,
        @intCast(sample_rate),
        @intCast(channels),
        @intFromEnum(application),
    ));

    return .{
        .handle = handle,
        .mem = mem,
        .sample_rate = sample_rate,
        .channels = channels,
    };
}

pub fn deinit(self: *Self, allocator: embed.mem.Allocator) void {
    allocator.free(self.mem);
    self.* = undefined;
}

pub fn frameSizeForMs(self: *const Self, ms: u32) u32 {
    return self.sample_rate * ms / 1000;
}

pub fn encode(self: *Self, pcm: []const i16, frame_size: u32, out: []u8) Error![]const u8 {
    const n = try opus_error.checkedPositive(binding.opus_encode(
        self.handle,
        pcm.ptr,
        @intCast(frame_size),
        out.ptr,
        @intCast(out.len),
    ));
    return out[0..n];
}

pub fn encodeFloat(self: *Self, pcm: []const f32, frame_size: u32, out: []u8) Error![]const u8 {
    const n = try opus_error.checkedPositive(binding.opus_encode_float(
        self.handle,
        pcm.ptr,
        @intCast(frame_size),
        out.ptr,
        @intCast(out.len),
    ));
    return out[0..n];
}

pub fn setBitrate(self: *Self, bitrate: u32) Error!void {
    try opus_error.checkError(binding.opus_encoder_ctl(
        self.handle,
        binding.OPUS_SET_BITRATE_REQUEST,
        @as(c_int, @intCast(bitrate)),
    ));
}

pub fn getBitrate(self: *Self) Error!u32 {
    var value: i32 = 0;
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_GET_BITRATE_REQUEST, &value));
    return @intCast(value);
}

pub fn setComplexity(self: *Self, complexity: u4) Error!void {
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_SET_COMPLEXITY_REQUEST, @as(c_int, complexity)));
}

pub fn setSignal(self: *Self, signal: Signal) Error!void {
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_SET_SIGNAL_REQUEST, @intFromEnum(signal)));
}

pub fn setBandwidth(self: *Self, bandwidth: Bandwidth) Error!void {
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_SET_BANDWIDTH_REQUEST, @intFromEnum(bandwidth)));
}

pub fn setVbr(self: *Self, enable: bool) Error!void {
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_SET_VBR_REQUEST, @as(c_int, @intFromBool(enable))));
}

pub fn setDtx(self: *Self, enable: bool) Error!void {
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_SET_DTX_REQUEST, @as(c_int, @intFromBool(enable))));
}

pub fn resetState(self: *Self) Error!void {
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_RESET_STATE));
}

test "opus/unit_tests/Encoder/init_and_controls" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expect(getSize(1) > 0);

    var encoder = try Self.init(testing.allocator, 48_000, 1, .audio);
    defer encoder.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 48_000), encoder.sample_rate);
    try testing.expectEqual(@as(u8, 1), encoder.channels);
    try testing.expectEqual(@as(u32, 960), encoder.frameSizeForMs(20));

    try encoder.setBitrate(64_000);
    try testing.expect(try encoder.getBitrate() > 0);
    try encoder.setComplexity(10);
    try encoder.setSignal(.music);
    try encoder.setBandwidth(.fullband);
    try encoder.setVbr(false);
    try encoder.setDtx(false);
    try encoder.resetState();
}
