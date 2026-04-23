//! Runtime integration runner — low-level tests for `net.make2(...).Runtime`.
//!
//! Each sub-case lives under `integration/runtime/<case>.zig` and takes the
//! already-instantiated `Net2` namespace from `net.make2(...)`.

const stdz = @import("stdz");
const testing_api = @import("testing");

const poll_read_interrupt = @import("runtime/poll_wake_read.zig");
const poll_read_waits_for_data = @import("runtime/poll_read_waits_for_data.zig");
const poll_write_interrupt = @import("runtime/poll_wake_write.zig");
const tcp_bind_loopback = @import("runtime/tcp_bind_loopback.zig");
const udp_bind_loopback = @import("runtime/udp_bind_loopback.zig");

pub fn make(comptime Net2: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("poll_read_interrupt", poll_read_interrupt.make(Net2));
            t.run("poll_read_waits_for_data", poll_read_waits_for_data.make(Net2));
            t.run("poll_write_interrupt", poll_write_interrupt.make(Net2));
            t.run("tcp_loopback_rw", tcp_bind_loopback.make(Net2));
            t.run("udp_loopback_rw", udp_bind_loopback.make(Net2));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
