//! TCP test runner — integration tests for the net-driven TCP path.
//!
//! Each sub-case lives under `tcp/<case>.zig` as its own `TestRunner` (`make(lib, net)`).
//!
//! Usage:
//!   const runner = @import("net/test_runner/integration/tcp.zig").make(lib, net);
//!   t.run("net/tcp", runner);

const stdz = @import("stdz");
const testing_api = @import("testing");

const ipv4_dial_listen = @import("tcp/ipv4_dial_listen.zig");
const ipv6_dial_listen = @import("tcp/ipv6_dial_listen.zig");
const dialer_dial_and_dial_context = @import("tcp/dialer_dial_and_dial_context.zig");
const listener_accept_reports_oom = @import("tcp/listener_accept_reports_oom.zig");
const dial_ctx_canceled_before_start = @import("tcp/dial_ctx_canceled_before_start.zig");
const dial_ctx_deadline_exceeded_before_start = @import("tcp/dial_ctx_deadline_exceeded_before_start.zig");
const dial_ctx_canceled_during_connect = @import("tcp/dial_ctx_canceled_during_connect.zig");
const dial_ctx_deadline_exceeded_during_connect = @import("tcp/dial_ctx_deadline_exceeded_during_connect.zig");
const dial_refused_keeps_specific_error = @import("tcp/dial_refused_keeps_specific_error.zig");
const conn_close_is_idempotent = @import("tcp/conn_close_is_idempotent.zig");
const conn_ops_after_close_return_closed = @import("tcp/conn_ops_after_close_return_closed.zig");
const read_canceled_ctx_maps_timed_out = @import("tcp/read_canceled_ctx_maps_timed_out.zig");
const write_canceled_ctx_maps_timed_out = @import("tcp/write_canceled_ctx_maps_timed_out.zig");
const close_releases_context_bindings = @import("tcp/close_releases_context_bindings.zig");
const conn_close_unblocks_blocked_read = @import("tcp/conn_close_unblocks_blocked_read.zig");
const listener_close_unblocks_blocked_accept = @import("tcp/listener_close_unblocks_blocked_accept.zig");
const read_context_clear_while_blocked_allows_read_to_continue = @import("tcp/read_context_clear_while_blocked_allows_read_to_continue.zig");
const read_deadline_ctx_maps_timed_out = @import("tcp/read_deadline_ctx_maps_timed_out.zig");
const write_deadline_ctx_maps_timed_out = @import("tcp/write_deadline_ctx_maps_timed_out.zig");
const read_timeout_set_while_blocked_maps_timed_out = @import("tcp/read_timeout_set_while_blocked_maps_timed_out.zig");
const read_timeout_set_while_read_and_write_blocked_maps_timed_out = @import("tcp/read_timeout_set_while_read_and_write_blocked_maps_timed_out.zig");
const read_timeout_clear_while_blocked_allows_read_to_continue = @import("tcp/read_timeout_clear_while_blocked_allows_read_to_continue.zig");
const write_context_set_while_blocked_maps_timed_out = @import("tcp/write_context_set_while_blocked_maps_timed_out.zig");
const write_timeout_set_while_blocked_maps_timed_out = @import("tcp/write_timeout_set_while_blocked_maps_timed_out.zig");
const write_timeout_clear_while_blocked_allows_write_to_continue = @import("tcp/write_timeout_clear_while_blocked_allows_write_to_continue.zig");
const write_waits_until_peer_drains = @import("tcp/write_waits_until_peer_drains.zig");
const read_timeout = @import("tcp/read_timeout.zig");
const read_full = @import("tcp/read_full.zig");
const read_eos_after_peer_shutdown_write = @import("tcp/read_eos_after_peer_shutdown_write.zig");
const write_timeout = @import("tcp/write_timeout.zig");
const conn_as_downcast = @import("tcp/conn_as_downcast.zig");
const multiple_accept = @import("tcp/multiple_accept.zig");
const conn_concurrent_bidirectional_rw = @import("tcp/conn_concurrent_bidirectional_rw.zig");
const listener_concurrent_accept = @import("tcp/listener_concurrent_accept.zig");

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("ipv4_dial_listen", ipv4_dial_listen.make(lib, net));
            t.run("ipv6_dial_listen", ipv6_dial_listen.make(lib, net));
            t.run("dialer_dial_and_dial_context", dialer_dial_and_dial_context.make(lib, net));
            t.run("listener_accept_reports_oom", listener_accept_reports_oom.make(lib, net));
            t.run("dial_ctx_canceled_before_start", dial_ctx_canceled_before_start.make(lib, net));
            t.run("dial_ctx_deadline_exceeded_before_start", dial_ctx_deadline_exceeded_before_start.make(lib, net));
            t.run("dial_ctx_canceled_during_connect", dial_ctx_canceled_during_connect.make(lib, net));
            t.run("dial_ctx_deadline_exceeded_during_connect", dial_ctx_deadline_exceeded_during_connect.make(lib, net));
            t.run("dial_refused_keeps_specific_error", dial_refused_keeps_specific_error.make(lib, net));
            t.run("conn_close_is_idempotent", conn_close_is_idempotent.make(lib, net));
            t.run("conn_ops_after_close_return_closed", conn_ops_after_close_return_closed.make(lib, net));
            t.run("read_canceled_ctx_maps_timed_out", read_canceled_ctx_maps_timed_out.make(lib, net));
            t.run("write_canceled_ctx_maps_timed_out", write_canceled_ctx_maps_timed_out.make(lib, net));
            t.run("close_releases_context_bindings", close_releases_context_bindings.make(lib, net));
            t.run("conn_close_unblocks_blocked_read", conn_close_unblocks_blocked_read.make(lib, net));
            t.run("listener_close_unblocks_blocked_accept", listener_close_unblocks_blocked_accept.make(lib, net));
            t.run("read_context_clear_while_blocked_allows_read_to_continue", read_context_clear_while_blocked_allows_read_to_continue.make(lib, net));
            t.run("read_deadline_ctx_maps_timed_out", read_deadline_ctx_maps_timed_out.make(lib, net));
            t.run("write_deadline_ctx_maps_timed_out", write_deadline_ctx_maps_timed_out.make(lib, net));
            t.run("read_timeout_set_while_blocked_maps_timed_out", read_timeout_set_while_blocked_maps_timed_out.make(lib, net));
            t.run("read_timeout_set_while_read_and_write_blocked_maps_timed_out", read_timeout_set_while_read_and_write_blocked_maps_timed_out.make(lib, net));
            t.run("read_timeout_clear_while_blocked_allows_read_to_continue", read_timeout_clear_while_blocked_allows_read_to_continue.make(lib, net));
            t.run("write_context_set_while_blocked_maps_timed_out", write_context_set_while_blocked_maps_timed_out.make(lib, net));
            t.run("write_timeout_set_while_blocked_maps_timed_out", write_timeout_set_while_blocked_maps_timed_out.make(lib, net));
            t.run("write_timeout_clear_while_blocked_allows_write_to_continue", write_timeout_clear_while_blocked_allows_write_to_continue.make(lib, net));
            t.run("write_waits_until_peer_drains", write_waits_until_peer_drains.make(lib, net));
            t.run("read_timeout", read_timeout.make(lib, net));
            t.run("read_full", read_full.make(lib, net));
            t.run("read_eos_after_peer_shutdown_write", read_eos_after_peer_shutdown_write.make(lib, net));
            t.run("write_timeout", write_timeout.make(lib, net));
            t.run("conn_as_downcast", conn_as_downcast.make(lib, net));
            t.run("multiple_accept", multiple_accept.make(lib, net));
            t.run("conn_concurrent_bidirectional_rw", conn_concurrent_bidirectional_rw.make(lib, net));
            t.run("listener_concurrent_accept", listener_concurrent_accept.make(lib, net));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
