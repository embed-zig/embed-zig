//! HTTP transport runner — unified per-case HTTP transport coverage.

const testing_api = @import("testing");

const local_returns_200 = @import("http_transport/local_returns_200.zig");
const local_returns_404 = @import("http_transport/local_returns_404.zig");
const default_user_agent_matches = @import("http_transport/default_user_agent_matches.zig");
const empty_user_agent_suppresses_default = @import("http_transport/empty_user_agent_suppresses_default.zig");
const context_deadline_exceeded = @import("http_transport/context_deadline_exceeded.zig");
const response_header_timeout_exceeded = @import("http_transport/response_header_timeout_exceeded.zig");
const response_header_timeout_does_not_limit_body_read = @import("http_transport/response_header_timeout_does_not_limit_body_read.zig");
const response_body_read_canceled_by_context = @import("http_transport/response_body_read_canceled_by_context.zig");
const response_body_read_deadline_exceeded_by_context = @import("http_transport/response_body_read_deadline_exceeded_by_context.zig");
const request_body_write_canceled_by_context = @import("http_transport/request_body_write_canceled_by_context.zig");
const request_body_write_deadline_exceeded_by_context = @import("http_transport/request_body_write_deadline_exceeded_by_context.zig");
const chunked_request_body_write_canceled_by_context = @import("http_transport/chunked_request_body_write_canceled_by_context.zig");
const chunked_request_body_write_deadline_exceeded_by_context = @import("http_transport/chunked_request_body_write_deadline_exceeded_by_context.zig");
const configured_max_header_bytes_allows_large_response_headers = @import("http_transport/configured_max_header_bytes_allows_large_response_headers.zig");
const response_body_larger_than_max_body_bytes_fails = @import("http_transport/response_body_larger_than_max_body_bytes_fails.zig");
const default_max_body_bytes_allows_large_response = @import("http_transport/default_max_body_bytes_allows_large_response.zig");
const large_response_streams_without_buffering_whole_body = @import("http_transport/large_response_streams_without_buffering_whole_body.zig");
const default_max_body_bytes_allows_large_request = @import("http_transport/default_max_body_bytes_allows_large_request.zig");
const large_request_streams_without_buffering_whole_body = @import("http_transport/large_request_streams_without_buffering_whole_body.zig");
const connect_method_is_rejected = @import("http_transport/connect_method_is_rejected.zig");
const https_connect_proxy_auth_required = @import("http_transport/https_connect_proxy_auth_required.zig");
const https_connect_proxy_auth_required_with_body = @import("http_transport/https_connect_proxy_auth_required_with_body.zig");
const https_connect_proxy_rejected = @import("http_transport/https_connect_proxy_rejected.zig");
const https_connect_proxy_rejected_with_body = @import("http_transport/https_connect_proxy_rejected_with_body.zig");
const https_connect_proxy_response_header_timeout = @import("http_transport/https_connect_proxy_response_header_timeout.zig");
const https_connect_proxy_tls_init_failure_closes_tunnel_conn = @import("http_transport/https_connect_proxy_tls_init_failure_closes_tunnel_conn.zig");
const https_proxy_userinfo_generates_proxy_authorization = @import("http_transport/https_proxy_userinfo_generates_proxy_authorization.zig");
const https_proxy_invalid_percent_encoding_is_rejected = @import("http_transport/https_proxy_invalid_percent_encoding_is_rejected.zig");
const https_proxy_oversized_userinfo_is_rejected = @import("http_transport/https_proxy_oversized_userinfo_is_rejected.zig");
const https_proxy_connect_headers_override_url_userinfo = @import("http_transport/https_proxy_connect_headers_override_url_userinfo.zig");
const idle_connection_is_reused = @import("http_transport/idle_connection_is_reused.zig");
const disable_keep_alives_forces_new_conn = @import("http_transport/disable_keep_alives_forces_new_conn.zig");
const max_idle_conns_one_keeps_only_one_idle_conn_across_hosts = @import("http_transport/max_idle_conns_one_keeps_only_one_idle_conn_across_hosts.zig");
const max_idle_conns_per_host_one_keeps_only_one_idle_conn = @import("http_transport/max_idle_conns_per_host_one_keeps_only_one_idle_conn.zig");
const close_idle_connections_forces_new_conn = @import("http_transport/close_idle_connections_forces_new_conn.zig");
const early_response_body_close_does_not_reuse_conn = @import("http_transport/early_response_body_close_does_not_reuse_conn.zig");
const idle_connection_timeout_forces_new_conn = @import("http_transport/idle_connection_timeout_forces_new_conn.zig");
const same_host_request_while_body_open_uses_second_conn = @import("http_transport/same_host_request_while_body_open_uses_second_conn.zig");
const max_conns_per_host_one_blocks_second_request_until_first_response_closes = @import("http_transport/max_conns_per_host_one_blocks_second_request_until_first_response_closes.zig");
const max_conns_per_host_two_allows_second_live_conn = @import("http_transport/max_conns_per_host_two_allows_second_live_conn.zig");
const max_conns_per_host_waiter_reuses_returned_idle_conn = @import("http_transport/max_conns_per_host_waiter_reuses_returned_idle_conn.zig");
const max_conns_per_host_waiter_deadline_exceeded = @import("http_transport/max_conns_per_host_waiter_deadline_exceeded.zig");
const max_conns_per_host_waiter_canceled = @import("http_transport/max_conns_per_host_waiter_canceled.zig");
const close_idle_connections_with_max_conns_per_host_does_not_leak_capacity = @import("http_transport/close_idle_connections_with_max_conns_per_host_does_not_leak_capacity.zig");
const chunked_request_uses_transfer_encoding = @import("http_transport/chunked_request_uses_transfer_encoding.zig");
const chunked_response_streams = @import("http_transport/chunked_response_streams.zig");
const eof_delimited_response_streams = @import("http_transport/eof_delimited_response_streams.zig");
const head_response_is_bodyless = @import("http_transport/head_response_is_bodyless.zig");
const status_204_response_is_bodyless = @import("http_transport/status_204_response_is_bodyless.zig");
const status_304_response_is_bodyless = @import("http_transport/status_304_response_is_bodyless.zig");
const informational_continue_then_final_response = @import("http_transport/informational_continue_then_final_response.zig");
const expect_continue_timeout_sends_body_without_informational = @import("http_transport/expect_continue_timeout_sends_body_without_informational.zig");
const final_response_without_continue_skips_request_body = @import("http_transport/final_response_without_continue_skips_request_body.zig");
const request_body_streams_before_round_trip_completes = @import("http_transport/request_body_streams_before_round_trip_completes.zig");
const response_body_streams_progressively = @import("http_transport/response_body_streams_progressively.zig");
const full_duplex_request_and_response = @import("http_transport/full_duplex_request_and_response.zig");
const bodyless_early_response_does_not_wait_for_blocked_request_body = @import("http_transport/bodyless_early_response_does_not_wait_for_blocked_request_body.zig");
const stale_idle_connection_retries_replayable_get = @import("http_transport/stale_idle_connection_retries_replayable_get.zig");
const stale_idle_connection_retries_idempotent_replayable_post = @import("http_transport/stale_idle_connection_retries_idempotent_replayable_post.zig");

pub fn make2(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            t.run("local_returns_200", local_returns_200.make(std, net));
            t.run("local_returns_404", local_returns_404.make(std, net));
            t.run("default_user_agent_matches", default_user_agent_matches.make(std, net));
            t.run("empty_user_agent_suppresses_default", empty_user_agent_suppresses_default.make(std, net));
            t.run("context_deadline_exceeded", context_deadline_exceeded.make(std, net));
            t.run("response_header_timeout_exceeded", response_header_timeout_exceeded.make(std, net));
            t.run("response_header_timeout_does_not_limit_body_read", response_header_timeout_does_not_limit_body_read.make(std, net));
            t.run("response_body_read_canceled_by_context", response_body_read_canceled_by_context.make(std, net));
            t.run("response_body_read_deadline_exceeded_by_context", response_body_read_deadline_exceeded_by_context.make(std, net));
            t.run("request_body_write_canceled_by_context", request_body_write_canceled_by_context.make(std, net));
            t.run("request_body_write_deadline_exceeded_by_context", request_body_write_deadline_exceeded_by_context.make(std, net));
            t.run("chunked_request_body_write_canceled_by_context", chunked_request_body_write_canceled_by_context.make(std, net));
            t.run("chunked_request_body_write_deadline_exceeded_by_context", chunked_request_body_write_deadline_exceeded_by_context.make(std, net));
            t.run("configured_max_header_bytes_allows_large_response_headers", configured_max_header_bytes_allows_large_response_headers.make(std, net));
            t.run("response_body_larger_than_max_body_bytes_fails", response_body_larger_than_max_body_bytes_fails.make(std, net));
            t.run("default_max_body_bytes_allows_large_response", default_max_body_bytes_allows_large_response.make(std, net));
            t.run("large_response_streams_without_buffering_whole_body", large_response_streams_without_buffering_whole_body.make(std, net));
            t.run("default_max_body_bytes_allows_large_request", default_max_body_bytes_allows_large_request.make(std, net));
            t.run("large_request_streams_without_buffering_whole_body", large_request_streams_without_buffering_whole_body.make(std, net));
            t.run("connect_method_is_rejected", connect_method_is_rejected.make(std, net));
            t.run("https_connect_proxy_auth_required", https_connect_proxy_auth_required.make(std, net));
            t.run("https_connect_proxy_auth_required_with_body", https_connect_proxy_auth_required_with_body.make(std, net));
            t.run("https_connect_proxy_rejected", https_connect_proxy_rejected.make(std, net));
            t.run("https_connect_proxy_rejected_with_body", https_connect_proxy_rejected_with_body.make(std, net));
            t.run("https_connect_proxy_response_header_timeout", https_connect_proxy_response_header_timeout.make(std, net));
            t.run("https_connect_proxy_tls_init_failure_closes_tunnel_conn", https_connect_proxy_tls_init_failure_closes_tunnel_conn.make(std, net));
            t.run("https_proxy_userinfo_generates_proxy_authorization", https_proxy_userinfo_generates_proxy_authorization.make(std, net));
            t.run("https_proxy_invalid_percent_encoding_is_rejected", https_proxy_invalid_percent_encoding_is_rejected.make(std, net));
            t.run("https_proxy_oversized_userinfo_is_rejected", https_proxy_oversized_userinfo_is_rejected.make(std, net));
            t.run("https_proxy_connect_headers_override_url_userinfo", https_proxy_connect_headers_override_url_userinfo.make(std, net));
            t.run("idle_connection_is_reused", idle_connection_is_reused.make(std, net));
            t.run("disable_keep_alives_forces_new_conn", disable_keep_alives_forces_new_conn.make(std, net));
            t.run("max_idle_conns_one_keeps_only_one_idle_conn_across_hosts", max_idle_conns_one_keeps_only_one_idle_conn_across_hosts.make(std, net));
            t.run("max_idle_conns_per_host_one_keeps_only_one_idle_conn", max_idle_conns_per_host_one_keeps_only_one_idle_conn.make(std, net));
            t.run("close_idle_connections_forces_new_conn", close_idle_connections_forces_new_conn.make(std, net));
            t.run("early_response_body_close_does_not_reuse_conn", early_response_body_close_does_not_reuse_conn.make(std, net));
            t.run("idle_connection_timeout_forces_new_conn", idle_connection_timeout_forces_new_conn.make(std, net));
            t.run("same_host_request_while_body_open_uses_second_conn", same_host_request_while_body_open_uses_second_conn.make(std, net));
            t.run("max_conns_per_host_one_blocks_second_request_until_first_response_closes", max_conns_per_host_one_blocks_second_request_until_first_response_closes.make(std, net));
            t.run("max_conns_per_host_two_allows_second_live_conn", max_conns_per_host_two_allows_second_live_conn.make(std, net));
            t.run("max_conns_per_host_waiter_reuses_returned_idle_conn", max_conns_per_host_waiter_reuses_returned_idle_conn.make(std, net));
            t.run("max_conns_per_host_waiter_deadline_exceeded", max_conns_per_host_waiter_deadline_exceeded.make(std, net));
            t.run("max_conns_per_host_waiter_canceled", max_conns_per_host_waiter_canceled.make(std, net));
            t.run("close_idle_connections_with_max_conns_per_host_does_not_leak_capacity", close_idle_connections_with_max_conns_per_host_does_not_leak_capacity.make(std, net));
            t.run("chunked_request_uses_transfer_encoding", chunked_request_uses_transfer_encoding.make(std, net));
            t.run("chunked_response_streams", chunked_response_streams.make(std, net));
            t.run("eof_delimited_response_streams", eof_delimited_response_streams.make(std, net));
            t.run("head_response_is_bodyless", head_response_is_bodyless.make(std, net));
            t.run("status_204_response_is_bodyless", status_204_response_is_bodyless.make(std, net));
            t.run("status_304_response_is_bodyless", status_304_response_is_bodyless.make(std, net));
            t.run("informational_continue_then_final_response", informational_continue_then_final_response.make(std, net));
            t.run("expect_continue_timeout_sends_body_without_informational", expect_continue_timeout_sends_body_without_informational.make(std, net));
            t.run("final_response_without_continue_skips_request_body", final_response_without_continue_skips_request_body.make(std, net));
            t.run("request_body_streams_before_round_trip_completes", request_body_streams_before_round_trip_completes.make(std, net));
            t.run("response_body_streams_progressively", response_body_streams_progressively.make(std, net));
            t.run("full_duplex_request_and_response", full_duplex_request_and_response.make(std, net));
            t.run("bodyless_early_response_does_not_wait_for_blocked_request_body", bodyless_early_response_does_not_wait_for_blocked_request_body.make(std, net));
            t.run("stale_idle_connection_retries_replayable_get", stale_idle_connection_retries_replayable_get.make(std, net));
            t.run("stale_idle_connection_retries_idempotent_replayable_post", stale_idle_connection_retries_idempotent_replayable_post.make(std, net));
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
