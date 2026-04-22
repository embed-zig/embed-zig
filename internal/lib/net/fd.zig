//! fd — internal non-blocking socket substrate for `net`.
//!
//! This namespace is intentionally kept separate from the public `net` API
//! while the new stream/packet implementation is validated in isolation.

const testing_api = @import("testing");
const netfd_mod = @import("fd/netfd.zig");
const stream_mod = @import("fd/Stream.zig");
const packet_mod = @import("fd/Packet.zig");
const listener_mod = @import("fd/Listener.zig");

pub fn NetFd(comptime lib: type) type {
    return netfd_mod.make(lib);
}

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
    pub const stream = @import("test_runner/integration/fd_stream.zig");
    pub const packet = @import("test_runner/integration/fd_packet.zig");
};

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = allocator;
            _ = @import("fd/SockAddr.zig");
            _ = @import("fd/Listener.zig");
            _ = @import("fd/netfd.zig");
            _ = @import("fd/Stream.zig");
            _ = @import("fd/Packet.zig");
            _ = @import("test_runner/integration/fd_stream.zig");
            _ = @import("test_runner/integration/fd_packet.zig");
        }
    }.run);
}
