//! HTTPS transport runner — unified per-case HTTPS transport coverage.

const testing_api = @import("testing");

const self_signed_round_trip = @import("https_transport/self_signed_round_trip.zig");
const idle_connection_is_reused = @import("https_transport/idle_connection_is_reused.zig");
const response_header_timeout_exceeded = @import("https_transport/response_header_timeout_exceeded.zig");
const max_conns_per_host_waiter_reuses_returned_idle_conn = @import("https_transport/max_conns_per_host_waiter_reuses_returned_idle_conn.zig");
const http2_alternate_transport_handles_negotiated_h2 = @import("https_transport/http2_alternate_transport_handles_negotiated_h2.zig");
const http2_alternate_transport_is_opt_in = @import("https_transport/http2_alternate_transport_is_opt_in.zig");
const response_body_read_canceled_by_context = @import("https_transport/response_body_read_canceled_by_context.zig");
const https_round_trip_via_connect_proxy = @import("https_transport/https_round_trip_via_connect_proxy.zig");
const https_connect_proxy_informational_then_tunnel_succeeds = @import("https_transport/https_connect_proxy_informational_then_tunnel_succeeds.zig");
const https_connect_proxy_success_response_with_body_is_rejected = @import("https_transport/https_connect_proxy_success_response_with_body_is_rejected.zig");
const https_connect_proxy_success_response_with_chunked_body_is_rejected = @import("https_transport/https_connect_proxy_success_response_with_chunked_body_is_rejected.zig");
const https_connect_proxy_auth_connection_is_reused = @import("https_transport/https_connect_proxy_auth_connection_is_reused.zig");
const https_connect_proxy_connection_is_reused = @import("https_transport/https_connect_proxy_connection_is_reused.zig");
const direct_https_without_proxy_bypasses_connect_proxy = @import("https_transport/direct_https_without_proxy_bypasses_connect_proxy.zig");
const tls_handshake_timeout_exceeded = @import("https_transport/tls_handshake_timeout_exceeded.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            t.run("self_signed_round_trip", self_signed_round_trip.make(std, net));
            t.run("idle_connection_is_reused", idle_connection_is_reused.make(std, net));
            t.run("response_header_timeout_exceeded", response_header_timeout_exceeded.make(std, net));
            t.run("max_conns_per_host_waiter_reuses_returned_idle_conn", max_conns_per_host_waiter_reuses_returned_idle_conn.make(std, net));
            t.run("http2_alternate_transport_handles_negotiated_h2", http2_alternate_transport_handles_negotiated_h2.make(std, net));
            t.run("http2_alternate_transport_is_opt_in", http2_alternate_transport_is_opt_in.make(std, net));
            t.run("response_body_read_canceled_by_context", response_body_read_canceled_by_context.make(std, net));
            t.run("https_round_trip_via_connect_proxy", https_round_trip_via_connect_proxy.make(std, net));
            t.run("https_connect_proxy_informational_then_tunnel_succeeds", https_connect_proxy_informational_then_tunnel_succeeds.make(std, net));
            t.run("https_connect_proxy_success_response_with_body_is_rejected", https_connect_proxy_success_response_with_body_is_rejected.make(std, net));
            t.run("https_connect_proxy_success_response_with_chunked_body_is_rejected", https_connect_proxy_success_response_with_chunked_body_is_rejected.make(std, net));
            t.run("https_connect_proxy_auth_connection_is_reused", https_connect_proxy_auth_connection_is_reused.make(std, net));
            t.run("https_connect_proxy_connection_is_reused", https_connect_proxy_connection_is_reused.make(std, net));
            t.run("direct_https_without_proxy_bypasses_connect_proxy", direct_https_without_proxy_bypasses_connect_proxy.make(std, net));
            t.run("tls_handshake_timeout_exceeded", tls_handshake_timeout_exceeded.make(std, net));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
