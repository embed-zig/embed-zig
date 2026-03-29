const embed = @import("embed");
const binding = @import("binding.zig");
const opus_error = @import("error.zig");
const types = @import("types.zig");
const Encoder = @import("Encoder.zig");

pub const Error = types.Error;
pub const Bandwidth = types.Bandwidth;

pub fn getSamples(data: []const u8, sample_rate: u32) Error!u32 {
    try validatePacketData(data);
    return @intCast(try opus_error.checkedPositive(binding.opus_packet_get_nb_samples(
        data.ptr,
        @intCast(data.len),
        @intCast(sample_rate),
    )));
}

pub fn getChannels(data: []const u8) Error!u8 {
    try validatePacketData(data);
    return @intCast(try opus_error.checkedPositive(binding.opus_packet_get_nb_channels(data.ptr)));
}

pub fn getBandwidth(data: []const u8) Error!Bandwidth {
    try validatePacketData(data);
    const ret = binding.opus_packet_get_bandwidth(data.ptr);
    try opus_error.checkError(ret);
    return @enumFromInt(ret);
}

pub fn getFrames(data: []const u8) Error!u32 {
    try validatePacketData(data);
    return @intCast(try opus_error.checkedPositive(binding.opus_packet_get_nb_frames(data.ptr, @intCast(data.len))));
}

fn validatePacketData(data: []const u8) Error!void {
    if (data.len == 0) return Error.InvalidPacket;
}

test "opus/unit_tests/packet/helpers_inspect_encoded_frame" {
    const std = @import("std");
    const testing = std.testing;

    var encoder = try Encoder.init(testing.allocator, 48_000, 1, .audio);
    defer encoder.deinit(testing.allocator);

    const pcm = [_]i16{0} ** 960;
    var out: [1500]u8 = undefined;
    const encoded = try encoder.encode(pcm[0..], 960, out[0..]);

    try testing.expect(encoded.len > 0);
    try testing.expectEqual(@as(u8, 1), try getChannels(encoded));
    try testing.expectEqual(@as(u32, 1), try getFrames(encoded));
    try testing.expectEqual(@as(u32, 960), try getSamples(encoded, 48_000));

    switch (try getBandwidth(encoded)) {
        .auto,
        .narrowband,
        .mediumband,
        .wideband,
        .superwideband,
        .fullband,
        => {},
    }
}

test "opus/unit_tests/packet/helpers_reject_empty_input" {
    const std = @import("std");
    const testing = std.testing;

    const empty = [_]u8{};

    try testing.expectError(Error.InvalidPacket, getChannels(empty[0..]));
    try testing.expectError(Error.InvalidPacket, getFrames(empty[0..]));
    try testing.expectError(Error.InvalidPacket, getSamples(empty[0..], 48_000));
    try testing.expectError(Error.InvalidPacket, getBandwidth(empty[0..]));
}
