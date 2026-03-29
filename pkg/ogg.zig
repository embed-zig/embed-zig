//! ogg — libogg bindings.
//!
//! Usage:
//!   const ogg = @import("ogg");
//!   var sync = ogg.Sync.init();

const binding_mod = @import("ogg/src/binding.zig");
const types = @import("ogg/src/types.zig");
pub const Page = @import("ogg/src/Page.zig");
pub const SyncState = binding_mod.SyncState;
pub const StreamState = binding_mod.StreamState;
pub const Packet = binding_mod.Packet;
pub const PageOutResult = types.PageOutResult;
pub const PacketOutResult = types.PacketOutResult;
pub const Sync = @import("ogg/src/Sync.zig");
pub const Stream = @import("ogg/src/Stream.zig");

pub const test_runner = struct {
    pub const ogg = @import("ogg/test_runner/ogg.zig");
};

test "ogg/unit_tests" {
    _ = @import("ogg/src/binding.zig");
    _ = @import("ogg/src/Page.zig");
    _ = @import("ogg/src/types.zig");
    _ = @import("ogg/src/Sync.zig");
    _ = @import("ogg/src/Stream.zig");
}

test "ogg/integration_tests/embed" {
    const lib = @import("embed_std").std;
    const testing = @import("testing");

    var t = testing.T.new(lib, .ogg_integration_embed);
    defer t.deinit();

    t.run("ogg", test_runner.ogg.make(lib));
    if (!t.wait()) return error.TestFailed;
}

test "ogg/integration_tests/std" {
    const lib = @import("std");
    const testing = @import("testing");

    var t = testing.T.new(lib, .ogg_integration_std);
    defer t.deinit();

    t.run("ogg", test_runner.ogg.make(lib));
    if (!t.wait()) return error.TestFailed;
}
