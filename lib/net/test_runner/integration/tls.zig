//! TLS test runner — deterministic local integration tests.
//!
//! Each sub-case lives under `tls/<case>.zig` as its own `TestRunner` (`make(lib)`).
//! Shared helpers and `runLoopbackCase` live in `tls/test_utils.zig`.
//!
//! These tests exercise the generic `net.tls` client and server paths using
//! local loopback listeners so the same behavior can be re-run on embedded
//! targets. Public-network smoke coverage is available separately via
//! `integration/public/tls_dial.zig` `make(...)`, which pins exact TLS versions against
//! `dns.alidns.com:853` in sequence.
//!
//! Usage:
//!   const runner = @import("net/test_runner/integration/tls.zig").make(lib);
//!   t.run("net/tls", runner);

const embed = @import("embed");
const testing_api = @import("testing");

const local_loopback_versions = @import("tls/local_loopback_versions.zig");
const tls13_configured_suites = @import("tls/tls13_configured_suites.zig");
const server_conn_handles_client_key_update = @import("tls/server_conn_handles_client_key_update.zig");
const client_conn_handles_server_key_update = @import("tls/client_conn_handles_server_key_update.zig");
const close_sends_close_notify_to_peer = @import("tls/close_sends_close_notify_to_peer.zig");
const listener_accepts_tls_client = @import("tls/listener_accepts_tls_client.zig");
const dialer_connects_to_tls_listener = @import("tls/dialer_connects_to_tls_listener.zig");
const dial_context_connects_to_tls_listener = @import("tls/dial_context_connects_to_tls_listener.zig");
const dial_context_canceled_before_start = @import("tls/dial_context_canceled_before_start.zig");
const conn_concurrent_bidirectional_rw = @import("tls/conn_concurrent_bidirectional_rw.zig");
const dialer_rejects_udp = @import("tls/dialer_rejects_udp.zig");
const invalid_listener_config_rejected = @import("tls/invalid_listener_config_rejected.zig");

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
            t.run("local_loopback_versions", local_loopback_versions.make(lib));
            t.run("tls13_configured_suites", tls13_configured_suites.make(lib));
            t.run("server_conn_handles_client_key_update", server_conn_handles_client_key_update.make(lib));
            t.run("client_conn_handles_server_key_update", client_conn_handles_server_key_update.make(lib));
            t.run("close_sends_close_notify_to_peer", close_sends_close_notify_to_peer.make(lib));
            t.run("listener_accepts_tls_client", listener_accepts_tls_client.make(lib));
            t.run("dialer_connects_to_tls_listener", dialer_connects_to_tls_listener.make(lib));
            t.run("dial_context_connects_to_tls_listener", dial_context_connects_to_tls_listener.make(lib));
            t.run("dial_context_canceled_before_start", dial_context_canceled_before_start.make(lib));
            t.run("conn_concurrent_bidirectional_rw", conn_concurrent_bidirectional_rw.make(lib));
            t.run("dialer_rejects_udp", dialer_rejects_udp.make(lib));
            t.run("invalid_listener_config_rejected", invalid_listener_config_rejected.make(lib));
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
