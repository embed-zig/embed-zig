//! UDP test runner — integration tests for the net-driven UDP path.
//!
//! Each sub-case lives under `udp/<case>.zig` as its own `TestRunner` (`make(lib, net)`).
//! Shared address / skip helpers: `integration/tcp/test_utils.zig`.
//!
//! Tests listenPacket (PacketConn), connected UDP (Conn), and as() downcast.
//!
//! Usage:
//!   const runner = @import("net/test_runner/integration/udp.zig").make(lib, net);
//!   t.run("net/udp", runner);

const stdz = @import("stdz");
const testing_api = @import("testing");

const ipv4_listen_packet = @import("udp/ipv4_listen_packet.zig");
const ipv6_listen_packet = @import("udp/ipv6_listen_packet.zig");
const bound_port_rejects_ipv6_sockets = @import("udp/bound_port_rejects_ipv6_sockets.zig");
const bound_port6_rejects_ipv4_sockets = @import("udp/bound_port6_rejects_ipv4_sockets.zig");
const read_timeout = @import("udp/read_timeout.zig");
const read_timeout_set_while_blocked_maps_timed_out = @import("udp/read_timeout_set_while_blocked_maps_timed_out.zig");
const read_timeout_clear_while_blocked_allows_read_to_continue = @import("udp/read_timeout_clear_while_blocked_allows_read_to_continue.zig");
const write_timeout_set_while_blocked_maps_timed_out = @import("udp/write_timeout_set_while_blocked_maps_timed_out.zig");
const dial_context = @import("udp/dial_context.zig");
const conn_read_timeout_set_while_blocked_maps_timed_out = @import("udp/conn_read_timeout_set_while_blocked_maps_timed_out.zig");
const conn_read_timeout_clear_while_blocked_allows_read_to_continue = @import("udp/conn_read_timeout_clear_while_blocked_allows_read_to_continue.zig");
const conn_zero_length_read_does_not_consume_datagram = @import("udp/conn_zero_length_read_does_not_consume_datagram.zig");
const conn_zero_length_datagram_is_not_eof = @import("udp/conn_zero_length_datagram_is_not_eof.zig");
const conn_close_unblocks_blocked_read = @import("udp/conn_close_unblocks_blocked_read.zig");
const packet_conn_zero_length_read_does_not_consume_datagram = @import("udp/packet_conn_zero_length_read_does_not_consume_datagram.zig");
const packet_conn_preserves_datagram_boundaries = @import("udp/packet_conn_preserves_datagram_boundaries.zig");
const packet_conn_concurrent_bidirectional_rw = @import("udp/packet_conn_concurrent_bidirectional_rw.zig");
const packet_conn_close_unblocks_blocked_read = @import("udp/packet_conn_close_unblocks_blocked_read.zig");
const dial_context_canceled_before_start = @import("udp/dial_context_canceled_before_start.zig");
const dial_context_deadline_exceeded_before_start = @import("udp/dial_context_deadline_exceeded_before_start.zig");
const dial_context_canceled_during_connect = @import("udp/dial_context_canceled_during_connect.zig");
const dial_context_deadline_exceeded_during_connect = @import("udp/dial_context_deadline_exceeded_during_connect.zig");
const packet_conn_as_downcast = @import("udp/packet_conn_as_downcast.zig");
const packet_conn_batch_as_udp_conn = @import("udp/packet_conn_batch_as_udp_conn.zig");
const conn_as_downcast = @import("udp/conn_as_downcast.zig");
const conn_ops_after_close = @import("udp/conn_ops_after_close.zig");
const packet_conn_ops_after_close = @import("udp/packet_conn_ops_after_close.zig");

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
            t.run("ipv4_listen_packet", ipv4_listen_packet.make(lib, net));
            t.run("ipv6_listen_packet", ipv6_listen_packet.make(lib, net));
            t.run("bound_port_rejects_ipv6_sockets", bound_port_rejects_ipv6_sockets.make(lib, net));
            t.run("bound_port6_rejects_ipv4_sockets", bound_port6_rejects_ipv4_sockets.make(lib, net));
            t.run("read_timeout", read_timeout.make(lib, net));
            t.run("read_timeout_set_while_blocked_maps_timed_out", read_timeout_set_while_blocked_maps_timed_out.make(lib, net));
            t.run("read_timeout_clear_while_blocked_allows_read_to_continue", read_timeout_clear_while_blocked_allows_read_to_continue.make(lib, net));
            t.run("write_timeout_set_while_blocked_maps_timed_out", write_timeout_set_while_blocked_maps_timed_out.make(lib, net));
            t.run("dial_context", dial_context.make(lib, net));
            t.run("conn_read_timeout_set_while_blocked_maps_timed_out", conn_read_timeout_set_while_blocked_maps_timed_out.make(lib, net));
            t.run("conn_read_timeout_clear_while_blocked_allows_read_to_continue", conn_read_timeout_clear_while_blocked_allows_read_to_continue.make(lib, net));
            t.run("conn_zero_length_read_does_not_consume_datagram", conn_zero_length_read_does_not_consume_datagram.make(lib, net));
            t.run("conn_zero_length_datagram_is_not_eof", conn_zero_length_datagram_is_not_eof.make(lib, net));
            t.run("conn_close_unblocks_blocked_read", conn_close_unblocks_blocked_read.make(lib, net));
            t.run("packet_conn_zero_length_read_does_not_consume_datagram", packet_conn_zero_length_read_does_not_consume_datagram.make(lib, net));
            t.run("packet_conn_preserves_datagram_boundaries", packet_conn_preserves_datagram_boundaries.make(lib, net));
            t.run("packet_conn_concurrent_bidirectional_rw", packet_conn_concurrent_bidirectional_rw.make(lib, net));
            t.run("packet_conn_close_unblocks_blocked_read", packet_conn_close_unblocks_blocked_read.make(lib, net));
            t.run("dial_context_canceled_before_start", dial_context_canceled_before_start.make(lib, net));
            t.run("dial_context_deadline_exceeded_before_start", dial_context_deadline_exceeded_before_start.make(lib, net));
            t.run("dial_context_canceled_during_connect", dial_context_canceled_during_connect.make(lib, net));
            t.run("dial_context_deadline_exceeded_during_connect", dial_context_deadline_exceeded_during_connect.make(lib, net));
            t.run("packet_conn_as_downcast", packet_conn_as_downcast.make(lib, net));
            t.run("packet_conn_batch_as_udp_conn", packet_conn_batch_as_udp_conn.make(lib, net));
            t.run("conn_as_downcast", conn_as_downcast.make(lib, net));
            t.run("conn_ops_after_close", conn_ops_after_close.make(lib, net));
            t.run("packet_conn_ops_after_close", packet_conn_ops_after_close.make(lib, net));
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
