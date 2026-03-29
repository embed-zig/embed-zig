//! TLS dial runner — public-network integration tests.
//!
//! This runner verifies that `net.tls.dial(...)` can reach a caller-provided
//! public DoT-style endpoint on port 853 using the same hostname for DNS
//! resolution and TLS `server_name`.
//!
//! Usage:
//!   const runner = @import("net/test_runner/tls_dial.zig").make(lib, "dns.alidns.com");
//!   t.run("net/tls_dial", runner);

const embed = @import("embed");
const net_mod = @import("../../net.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type, comptime host: []const u8) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            runImpl(lib, t, allocator, host) catch |err| {
                t.logErrorf("tls_dial runner failed: {}", .{err});
                return false;
            };
            return true;
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

fn runImpl(
    comptime lib: type,
    t: *testing_api.T,
    alloc: lib.mem.Allocator,
    comptime host: []const u8,
) !void {
    _ = t;
    const Net = net_mod.make(lib);
    const Addr = net_mod.netip.Addr;
    const AddrPort = net_mod.netip.AddrPort;
    const testing = struct {
        pub var allocator: lib.mem.Allocator = undefined;
        pub const expect = lib.testing.expect;
        pub const expectEqual = lib.testing.expectEqual;
        pub const expectEqualStrings = lib.testing.expectEqualStrings;
        pub const expectError = lib.testing.expectError;
    };
    testing.allocator = alloc;
    const PinnedVersionSuite = struct {
        version: Net.tls.ProtocolVersion,
        suite: ?Net.tls.CipherSuite = null,
    };

    var bundle: lib.crypto.Certificate.Bundle = .{};
    defer bundle.deinit(testing.allocator);
    try bundle.rescan(testing.allocator);

    var resolver = try Net.Resolver.init(testing.allocator, .{});
    defer resolver.deinit();

    var addrs: [8]Addr = undefined;
    const count = try resolver.lookupHost(host, &addrs);
    try testing.expect(count > 0);

    const server_addr = AddrPort.init(addrs[0], 853);

    inline for ([_]PinnedVersionSuite{
        .{ .version = .tls_1_2, .suite = .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 },
        .{ .version = .tls_1_2, .suite = .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 },
        .{ .version = .tls_1_3, .suite = .TLS_AES_128_GCM_SHA256 },
        .{ .version = .tls_1_3, .suite = .TLS_AES_256_GCM_SHA384 },
        .{ .version = .tls_1_3, .suite = .TLS_CHACHA20_POLY1305_SHA256 },
    }) |case| {
        try runPinnedVersionSuiteCase(lib, alloc, Net, server_addr, host, &bundle, case);
    }
}

fn runPinnedVersionSuiteCase(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    comptime NetType: type,
    server_addr: anytype,
    comptime host: []const u8,
    bundle: *const lib.crypto.Certificate.Bundle,
    comptime case: anytype,
) !void {
    const testing = lib.testing;
    const tls12_cipher_suites = if (case.suite) |suite|
        if (!suite.isTls13())
            &[_]NetType.tls.CipherSuite{suite}
        else
            &NetType.tls.DEFAULT_TLS12_CIPHER_SUITES
    else
        &NetType.tls.DEFAULT_TLS12_CIPHER_SUITES;
    const tls13_cipher_suites = if (case.suite) |suite|
        if (suite.isTls13())
            &[_]NetType.tls.CipherSuite{suite}
        else
            &NetType.tls.DEFAULT_TLS13_CIPHER_SUITES
    else
        &NetType.tls.DEFAULT_TLS13_CIPHER_SUITES;

    if (case.suite) |suite|
        try testing.expectEqual(case.version == .tls_1_3, suite.isTls13());

    var tls_conn = try NetType.tls.dial(allocator, .tcp, server_addr, .{
        .server_name = host,
        .root_cas = bundle,
        .min_version = case.version,
        .max_version = case.version,
        .tls12_cipher_suites = tls12_cipher_suites,
        .tls13_cipher_suites = tls13_cipher_suites,
    });
    defer tls_conn.deinit();

    const tls_impl = try tls_conn.as(NetType.tls.Conn);
    try tls_impl.handshake();
    try testing.expectEqual(case.version, tls_impl.handshake_state.version);
    if (case.suite) |suite| {
        try testing.expectEqual(suite, tls_impl.handshake_state.cipher_suite);
    }
}
