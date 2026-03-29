//! opus — libopus bindings.
//!
//! Usage:
//!   const opus = @import("opus");
//!   var enc = try opus.Encoder.init(allocator, 48_000, 1, .audio);

const binding_mod = @import("opus/src/binding.zig");
const packet = @import("opus/src/packet.zig");
const types = @import("opus/src/types.zig");

pub const Error = types.Error;
pub const Application = types.Application;
pub const Signal = types.Signal;
pub const Bandwidth = types.Bandwidth;
pub const Encoder = @import("opus/src/Encoder.zig");
pub const Decoder = @import("opus/src/Decoder.zig");

pub fn getVersionString() [*:0]const u8 {
    return binding_mod.getVersionString();
}

pub fn packetGetSamples(data: []const u8, sample_rate: u32) Error!u32 {
    return packet.getSamples(data, sample_rate);
}

pub fn packetGetChannels(data: []const u8) Error!u8 {
    return packet.getChannels(data);
}

pub fn packetGetBandwidth(data: []const u8) Error!Bandwidth {
    return packet.getBandwidth(data);
}

pub fn packetGetFrames(data: []const u8) Error!u32 {
    return packet.getFrames(data);
}

pub const test_runner = struct {
    pub const opus = @import("opus/test_runner/opus.zig");
};

test "opus/unit_tests" {
    _ = @import("opus/src/types.zig");
    _ = @import("opus/src/error.zig");
    _ = @import("opus/src/packet.zig");
    _ = @import("opus/src/Encoder.zig");
    _ = @import("opus/src/Decoder.zig");
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
