//! opus - libopus bindings.
//!
//! Usage:
//!   const opus = @import("opus");
//!   var enc = try opus.Encoder.init(allocator, 48_000, 1, .audio);

const glib = @import("glib");
const gstd = @import("gstd");
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
    pub const unit = @import("opus/test_runner/unit.zig");
    pub const integration = @import("opus/test_runner/integration.zig");
};

test "opus/unit_tests/std" {
    var t = glib.testing.T.new(gstd.runtime.std, .opus_unit_std);
    defer t.deinit();

    t.run("unit", test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "opus/unit_tests/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .opus_unit_embed_std);
    defer t.deinit();

    t.run("unit", test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "opus/integration_tests/std" {
    var t = glib.testing.T.new(gstd.runtime.std, .opus_integration_std);
    defer t.deinit();

    t.run("integration", test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "opus/integration_tests/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .opus_integration_embed_std);
    defer t.deinit();

    t.run("integration", test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
