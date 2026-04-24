//! Resolver public DNS runner — public-network integration tests.
//!
//! These tests hit caller-provided public recursive resolver IPs directly, so
//! they are intended for environments with real network connectivity.
//! The provided `server_name` is used both as the TLS/DoH server name and as
//! the DNS name queried by the smoke tests.
//!
//! Usage:
//!   const runner = @import("net/test_runner/integration/public/resolver_dns.zig").make(
//!       lib,
//!       net,
//!       &.{ "223.5.5.5", "223.6.6.6" },
//!       "dns.alidns.com",
//!   );
//!   t.run("net/resolver_dns", runner);

const stdz = @import("stdz");
const resolver_mod = @import("../../../Resolver.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type, comptime net: type, comptime ips: []const []const u8, comptime server_name: []const u8) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            runImpl(lib, net, t, allocator, ips, server_name) catch |err| {
                t.logErrorf("resolver_dns runner failed: {}", .{err});
                return false;
            };
            return true;
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

fn runImpl(
    comptime lib: type,
    comptime net: type,
    t: *testing_api.T,
    alloc: lib.mem.Allocator,
    comptime ips: []const []const u8,
    comptime server_name: []const u8,
) !void {
    _ = t;
    const R = resolver_mod.Resolver(lib, net);
    const Addr = net.netip.Addr;
    const testing = struct {
        pub var allocator: lib.mem.Allocator = undefined;
        pub const expect = lib.testing.expect;
        pub const expectEqual = lib.testing.expectEqual;
        pub const expectEqualStrings = lib.testing.expectEqualStrings;
        pub const expectError = lib.testing.expectError;
    };
    testing.allocator = alloc;
    const resolver_spawn_config: lib.Thread.SpawnConfig = .{
        .stack_size = 128 * 1024,
    };

    comptime {
        if (ips.len == 0) @compileError("resolver public DNS runner requires at least one IP");
        if (ips.len < 2) @compileError("resolver public DNS runner requires at least two IPs");
    }

    const Runner = struct {
        fn lookupHostRealDnsUdp() !void {
            var resolver = try R.init(testing.allocator, .{
                .servers = &.{R.Server.init(ips[0], .udp)},
                .mode = .ipv4_only,
                .timeout_ms = 3000,
                .attempts = 2,
                .spawn_config = resolver_spawn_config,
            });
            defer resolver.deinit();

            var addrs: [8]Addr = undefined;
            const count = try resolver.lookupHost(server_name, &addrs);
            try testing.expect(count > 0);
        }

        fn lookupHostRealDnsTcp() !void {
            var resolver = try R.init(testing.allocator, .{
                .servers = &.{R.Server.init(ips[0], .tcp)},
                .mode = .ipv4_only,
                .timeout_ms = 3000,
                .attempts = 2,
                .spawn_config = resolver_spawn_config,
            });
            defer resolver.deinit();

            var addrs: [8]Addr = undefined;
            const count = try resolver.lookupHost(server_name, &addrs);
            try testing.expect(count > 0);
        }

        fn lookupHostRealDnsTls() !void {
            var resolver = try R.init(testing.allocator, .{
                .servers = &.{R.Server.init(ips[0], .tls)},
                .mode = .ipv4_only,
                .timeout_ms = 5000,
                .attempts = 2,
                .spawn_config = resolver_spawn_config,
            });
            defer resolver.deinit();

            var addrs: [8]Addr = undefined;
            const count = try resolver.lookupHost(server_name, &addrs);
            try testing.expect(count > 0);
        }

        fn lookupHostRealDnsDoh() !void {
            var resolver = try R.init(testing.allocator, .{
                .servers = &.{R.Server.init(ips[0], .doh)},
                .mode = .ipv4_only,
                .timeout_ms = 5000,
                .attempts = 2,
                .spawn_config = resolver_spawn_config,
            });
            defer resolver.deinit();

            var addrs: [8]Addr = undefined;
            const count = try resolver.lookupHost(server_name, &addrs);
            try testing.expect(count > 0);
        }

        fn lookupHostUdpTcpParallel() !void {
            var resolver = try R.init(testing.allocator, .{
                .servers = &.{
                    R.Server.init(ips[0], .udp),
                    R.Server.init(ips[1], .tcp),
                },
                .mode = .ipv4_only,
                .timeout_ms = 3000,
                .attempts = 2,
                .spawn_config = resolver_spawn_config,
            });
            defer resolver.deinit();

            var addrs: [8]Addr = undefined;
            const count = try resolver.lookupHost(server_name, &addrs);
            try testing.expect(count > 0);
        }
    };

    try Runner.lookupHostRealDnsUdp();
    try Runner.lookupHostRealDnsTcp();
    try Runner.lookupHostRealDnsTls();
    try Runner.lookupHostRealDnsDoh();
    try Runner.lookupHostUdpTcpParallel();
}
