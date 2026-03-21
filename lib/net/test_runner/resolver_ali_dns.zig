//! Resolver AliDNS test runner — public-network integration tests.
//!
//! These tests hit public AliDNS servers directly, so they are intended for
//! environments with real network connectivity.
//!
//! Usage:
//!   try @import("net/test_runner/resolver_ali_dns.zig").run(lib);

const net_mod = @import("../../net.zig");
const resolver_mod = @import("../Resolver.zig");

pub fn run(comptime lib: type) !void {
    const R = resolver_mod.Resolver(lib);
    const Addr = lib.net.Address;
    const testing = lib.testing;
    const log = lib.log.scoped(.resolver_ali_dns);

    const Runner = struct {
        fn lookupHostRealDnsUdp() !void {
            var resolver = try R.init(testing.allocator, .{
                .servers = &.{R.Server.init(R.dns.ali.v4_1, .udp)},
                .mode = .ipv4_only,
                .timeout_ms = 3000,
                .attempts = 2,
            });
            defer resolver.deinit();

            var addrs: [8]Addr = undefined;
            const count = try resolver.lookupHost("public.alidns.com", &addrs);
            try testing.expect(count > 0);
        }

        fn lookupHostRealDnsTcp() !void {
            var resolver = try R.init(testing.allocator, .{
                .servers = &.{R.Server.init(R.dns.ali.v4_1, .tcp)},
                .mode = .ipv4_only,
                .timeout_ms = 3000,
                .attempts = 2,
            });
            defer resolver.deinit();

            var addrs: [8]Addr = undefined;
            const count = try resolver.lookupHost("public.alidns.com", &addrs);
            try testing.expect(count > 0);
        }

        fn lookupHostUdpTcpParallel() !void {
            var resolver = try R.init(testing.allocator, .{
                .servers = &.{
                    R.Server.init(R.dns.ali.v4_1, .udp),
                    R.Server.init(R.dns.ali.v4_2, .tcp),
                },
                .mode = .ipv4_only,
                .timeout_ms = 3000,
                .attempts = 2,
            });
            defer resolver.deinit();

            var addrs: [8]Addr = undefined;
            const count = try resolver.lookupHost("public.alidns.com", &addrs);
            try testing.expect(count > 0);
        }
    };

    log.info("=== resolver ali_dns test_runner start ===", .{});
    try Runner.lookupHostRealDnsUdp();
    try Runner.lookupHostRealDnsTcp();
    try Runner.lookupHostUdpTcpParallel();
    log.info("=== resolver ali_dns test_runner done ===", .{});
}
