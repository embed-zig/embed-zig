//! fd — internal non-blocking socket substrate for `net`.
//!
//! This namespace is intentionally kept separate from the public `net` API
//! while the new stream/packet implementation is validated in isolation.

const stream_mod = @import("fd/Stream.zig");
const packet_mod = @import("fd/Packet.zig");
const listener_mod = @import("fd/Listener.zig");

pub fn Stream(comptime lib: type) type {
    return stream_mod.Stream(lib);
}

pub fn Packet(comptime lib: type) type {
    return packet_mod.Packet(lib);
}

pub fn Listener(comptime lib: type) type {
    return listener_mod.Listener(lib);
}

pub const test_runner = struct {
    pub const stream = @import("test_runner/fd_stream.zig");
    pub const packet = @import("test_runner/fd_packet.zig");
};

test "net/unit_tests/fd" {
    _ = @import("fd/SockAddr.zig");
    _ = @import("fd/Listener.zig");
    _ = @import("fd/Stream.zig");
    _ = @import("fd/Packet.zig");
    _ = @import("test_runner/fd_stream.zig");
    _ = @import("test_runner/fd_packet.zig");
}
