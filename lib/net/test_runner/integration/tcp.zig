//! TCP test runner — integration tests for net.make(lib) TCP path.
//!
//! Each sub-case lives under `tcp/<case>.zig` as its own `TestRunner` (`make(lib)`).
//!
//! Usage:
//!   const runner = @import("net/test_runner/integration/tcp.zig").make(lib);
//!   t.run("net/tcp", runner);

const embed = @import("embed");
const testing_api = @import("testing");

const ipv4_dial_listen = @import("tcp/ipv4_dial_listen.zig");
const ipv6_dial_listen = @import("tcp/ipv6_dial_listen.zig");
const dialer_dial_and_dial_context = @import("tcp/dialer_dial_and_dial_context.zig");
const listener_accept_reports_oom = @import("tcp/listener_accept_reports_oom.zig");
const dial_ctx_canceled_before_start = @import("tcp/dial_ctx_canceled_before_start.zig");
const dial_ctx_deadline_exceeded_before_start = @import("tcp/dial_ctx_deadline_exceeded_before_start.zig");
const dial_ctx_canceled_during_connect = @import("tcp/dial_ctx_canceled_during_connect.zig");
const dial_ctx_deadline_exceeded_during_connect = @import("tcp/dial_ctx_deadline_exceeded_during_connect.zig");
const read_canceled_ctx_maps_timed_out = @import("tcp/read_canceled_ctx_maps_timed_out.zig");
const read_deadline_ctx_maps_timed_out = @import("tcp/read_deadline_ctx_maps_timed_out.zig");
const read_timeout = @import("tcp/read_timeout.zig");
const read_full = @import("tcp/read_full.zig");
const read_eos_after_peer_shutdown_write = @import("tcp/read_eos_after_peer_shutdown_write.zig");
const write_timeout = @import("tcp/write_timeout.zig");
const conn_as_downcast = @import("tcp/conn_as_downcast.zig");
const multiple_accept = @import("tcp/multiple_accept.zig");
const conn_concurrent_bidirectional_rw = @import("tcp/conn_concurrent_bidirectional_rw.zig");
const listener_concurrent_accept = @import("tcp/listener_concurrent_accept.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("ipv4_dial_listen", ipv4_dial_listen.make(lib));
            t.run("ipv6_dial_listen", ipv6_dial_listen.make(lib));
            t.run("dialer_dial_and_dial_context", dialer_dial_and_dial_context.make(lib));
            t.run("listener_accept_reports_oom", listener_accept_reports_oom.make(lib));
            t.run("dial_ctx_canceled_before_start", dial_ctx_canceled_before_start.make(lib));
            t.run("dial_ctx_deadline_exceeded_before_start", dial_ctx_deadline_exceeded_before_start.make(lib));
            t.run("dial_ctx_canceled_during_connect", dial_ctx_canceled_during_connect.make(lib));
            t.run("dial_ctx_deadline_exceeded_during_connect", dial_ctx_deadline_exceeded_during_connect.make(lib));
            t.run("read_canceled_ctx_maps_timed_out", read_canceled_ctx_maps_timed_out.make(lib));
            t.run("read_deadline_ctx_maps_timed_out", read_deadline_ctx_maps_timed_out.make(lib));
            t.run("read_timeout", read_timeout.make(lib));
            t.run("read_full", read_full.make(lib));
            t.run("read_eos_after_peer_shutdown_write", read_eos_after_peer_shutdown_write.make(lib));
            t.run("write_timeout", write_timeout.make(lib));
            t.run("conn_as_downcast", conn_as_downcast.make(lib));
            t.run("multiple_accept", multiple_accept.make(lib));
            t.run("conn_concurrent_bidirectional_rw", conn_concurrent_bidirectional_rw.make(lib));
            t.run("listener_concurrent_accept", listener_concurrent_accept.make(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
