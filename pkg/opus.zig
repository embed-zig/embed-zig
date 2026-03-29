//! opus — libopus bindings.
//!
//! Usage:
//!   const opus = @import("opus");
//!   var enc = try opus.Encoder.init(allocator, 48_000, 1, .audio);

const binding_mod = @import("opus/src/binding.zig");
const types = @import("opus/src/types.zig");

pub const Error = types.Error;
pub const Application = types.Application;
pub const Signal = types.Signal;
pub const Bandwidth = types.Bandwidth;
pub const Encoder = @import("opus/src/Encoder.zig");
pub const Decoder = @import("opus/src/Decoder.zig");
pub const Packet = @import("opus/src/Packet.zig");

pub fn getVersionString() [*:0]const u8 {
    return binding_mod.getVersionString();
}

pub fn packetGetSamples(data: []const u8, sample_rate: u32) Error!u32 {
    return Packet.getSamples(data, sample_rate);
}

pub fn packetGetChannels(data: []const u8) Error!u8 {
    return Packet.getChannels(data);
}

pub fn packetGetBandwidth(data: []const u8) Error!Bandwidth {
    return Packet.getBandwidth(data);
}

pub fn packetGetFrames(data: []const u8) Error!u32 {
    return Packet.getFrames(data);
}

pub const test_runner = struct {
    pub const opus = @import("opus/test_runner/opus.zig");
};

test "opus/unit_tests" {
    _ = @import("opus/src/types.zig");
    _ = @import("opus/src/error.zig");
    _ = @import("opus/src/Packet.zig");
    _ = @import("opus/src/Encoder.zig");
    _ = @import("opus/src/Decoder.zig");
}

test "opus/unit_tests/root_surface_exposes_packet_namespace" {
    const std = @import("std");
    const testing = std.testing;

    var encoder = try Encoder.init(testing.allocator, 48_000, 1, .audio);
    defer encoder.deinit(testing.allocator);

    const pcm = [_]i16{0} ** 960;
    var out: [1500]u8 = undefined;
    const packet_data = try encoder.encode(pcm[0..], 960, out[0..]);

    try testing.expectEqual(try packetGetChannels(packet_data), try Packet.getChannels(packet_data));
    try testing.expectEqual(try packetGetFrames(packet_data), try Packet.getFrames(packet_data));
    try testing.expectEqual(try packetGetSamples(packet_data, 48_000), try Packet.getSamples(packet_data, 48_000));
    try testing.expectEqual(try packetGetBandwidth(packet_data), try Packet.getBandwidth(packet_data));
}

test "opus/integration_tests/embed" {
    const lib = @import("embed_std").std;
    const testing = @import("testing");

    var t = testing.T.new(lib, .opus_integration_embed);
    defer t.deinit();

    t.run("opus", test_runner.opus.make(lib));
    if (!t.wait()) return error.TestFailed;
}

test "opus/integration_tests/std" {
    const lib = @import("std");
    const testing = @import("testing");

    var t = testing.T.new(lib, .opus_integration_std);
    defer t.deinit();

    t.run("opus", test_runner.opus.make(lib));
    if (!t.wait()) return error.TestFailed;
}
