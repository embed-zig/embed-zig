const embed = @import("embed");
const binding = @import("binding.zig");
const opus_error = @import("error.zig");
const Error = @import("types.zig").Error;

const Self = @This();

handle: *binding.OpusDecoder,
mem: []align(16) u8,
sample_rate: u32,
channels: u8,

pub fn getSize(channels: u8) usize {
    return @intCast(binding.opus_decoder_get_size(@intCast(channels)));
}

pub fn init(
    allocator: embed.mem.Allocator,
    sample_rate: u32,
    channels: u8,
) (Error || embed.mem.Allocator.Error)!Self {
    const size = getSize(channels);
    const mem = try allocator.alignedAlloc(u8, .@"16", size);
    errdefer allocator.free(mem);

    const handle: *binding.OpusDecoder = @ptrCast(mem.ptr);
    try opus_error.checkError(binding.opus_decoder_init(handle, @intCast(sample_rate), @intCast(channels)));

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

pub fn decode(self: *Self, data: []const u8, pcm: []i16, fec: bool) Error![]const i16 {
    const frame_size: c_int = @intCast(pcm.len);
    const n = try opus_error.checkedPositive(binding.opus_decode(
        self.handle,
        data.ptr,
        @intCast(data.len),
        pcm.ptr,
        frame_size,
        @intFromBool(fec),
    ));
    return pcm[0..n];
}

pub fn decodeFloat(self: *Self, data: []const u8, pcm: []f32, fec: bool) Error![]const f32 {
    const frame_size: c_int = @intCast(pcm.len);
    const n = try opus_error.checkedPositive(binding.opus_decode_float(
        self.handle,
        data.ptr,
        @intCast(data.len),
        pcm.ptr,
        frame_size,
        @intFromBool(fec),
    ));
    return pcm[0..n];
}

pub fn plc(self: *Self, pcm: []i16) Error![]const i16 {
    const frame_size: c_int = @intCast(pcm.len);
    const n = try opus_error.checkedPositive(binding.opus_decode(self.handle, null, 0, pcm.ptr, frame_size, 0));
    return pcm[0..n];
}

pub fn getSampleRate(self: *Self) Error!u32 {
    var value: i32 = 0;
    try opus_error.checkError(binding.opus_decoder_ctl(self.handle, binding.OPUS_GET_SAMPLE_RATE_REQUEST, &value));
    return @intCast(value);
}

pub fn resetState(self: *Self) Error!void {
    try opus_error.checkError(binding.opus_decoder_ctl(self.handle, binding.OPUS_RESET_STATE));
}

test "opus/unit_tests/Decoder/init_and_query_sample_rate" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expect(getSize(1) > 0);

    var decoder = try Self.init(testing.allocator, 48_000, 1);
    defer decoder.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 48_000), decoder.sample_rate);
    try testing.expectEqual(@as(u8, 1), decoder.channels);
    try testing.expectEqual(@as(u32, 960), decoder.frameSizeForMs(20));
    try testing.expectEqual(@as(u32, 48_000), try decoder.getSampleRate());
    try decoder.resetState();
}
