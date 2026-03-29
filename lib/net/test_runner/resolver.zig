//! Resolver fake test runner — unit tests and local fake-DNS integration tests.
//!
//! Uses only local loopback servers, so it can run in environments without
//! public network access and can be invoked directly from platform runners.
//!
//! Usage:
//!   const runner = @import("net/test_runner/resolver.zig").make(lib);
//!   t.run("net/resolver", runner);

const std = @import("std");
const embed = @import("embed");
const io = @import("io");
const testing_api = @import("testing");
const net_mod = @import("../../net.zig");
const context_mod = @import("context");
const resolver_mod = @import("../Resolver.zig");
const fixtures = @import("../tls/test_fixtures.zig");
const Conn = net_mod.Conn;

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            runImpl(lib, t, allocator) catch |err| {
                t.logErrorf("resolver runner failed: {}", .{err});
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

fn runImpl(comptime lib: type, t: *testing_api.T, alloc: lib.mem.Allocator) !void {
    _ = t;
    const R = resolver_mod.Resolver(lib);
    const Net = net_mod.make(lib);
    const Addr = net_mod.netip.Addr;
    const AddrPort = net_mod.netip.AddrPort;
    const PacketConn = net_mod.PacketConn;
    const testing = struct {
        pub var allocator: lib.mem.Allocator = undefined;
        pub const expect = lib.testing.expect;
        pub const expectEqual = lib.testing.expectEqual;
        pub const expectEqualStrings = lib.testing.expectEqualStrings;
        pub const expectError = lib.testing.expectError;
    };
    testing.allocator = alloc;

    const Runner = struct {
        fn addr4(port: u16) AddrPort {
            return AddrPort.from4(.{ 127, 0, 0, 1 }, port);
        }

        fn addr6(comptime text: []const u8, port: u16) AddrPort {
            return AddrPort.init(comptime Addr.parse(text) catch unreachable, port);
        }

        fn listenerPort(ln: net_mod.Listener, comptime NetNs: type) !u16 {
            const typed = try ln.as(NetNs.TcpListener);
            return typed.port();
        }

        fn tlsListenerPort(ln: net_mod.Listener, comptime NetNs: type) !u16 {
            const typed = try ln.as(NetNs.tls.Listener);
            const inner = try typed.inner.as(NetNs.TcpListener);
            return inner.port();
        }

        fn initResolver(options: R.Options) !R {
            var owned = options;
            // Resolver workers exercise relatively deep host-side networking/TLS
            // stacks in compat tests, so give them an explicit host test stack.
            owned.spawn_config = .{ .stack_size = 1024 * 1024 };
            return R.init(testing.allocator, owned);
        }

        const test_spawn_config: lib.Thread.SpawnConfig = .{
            .stack_size = 64 * 1024,
        };

        fn optionsDefaults() !void {
            var r = try initResolver(.{});
            defer r.deinit();
            try testing.expectEqual(@as(u32, 1000), r.options.timeout_ms);
            try testing.expectEqual(@as(u32, 2), r.options.attempts);
            try testing.expectEqual(R.QueryMode.ipv4_only, r.options.mode);
            try testing.expectEqual(@as(usize, 4), r.options.servers.len);
        }

        fn serverProtocolConfig() !void {
            const s1 = R.Server.init(R.dns.ali.v4_1, .udp);
            const s2 = R.Server.init(R.dns.ali.v4_2, .tls);
            const s3 = R.Server.init(R.dns.google.v4_1, .doh);
            try testing.expectEqual(R.Protocol.udp, s1.protocol);
            try testing.expectEqual(R.Protocol.tls, s2.protocol);
            try testing.expectEqual(R.Protocol.doh, s3.protocol);
            try testing.expectEqualStrings("/dns-query", s3.doh_path);
        }

        fn lookupHostIgnoresEarlyNXDOMAINWhenLaterServerSucceeds() !void {
            var negative_pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer negative_pc.deinit();

            const negative_impl = try negative_pc.as(Net.UdpConn);
            const negative_port = try negative_impl.boundPort();
            var negative_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(server_pc: PacketConn) void {
                    var req_buf: [512]u8 = undefined;
                    const req = server_pc.readFrom(&req_buf) catch return;

                    var resp_buf: [512]u8 = undefined;
                    const resp_len = buildErrorResponse(R, req_buf[0..req.bytes_read], 3, &resp_buf) catch return;
                    _ = server_pc.writeTo(resp_buf[0..resp_len], @ptrCast(&req.addr), req.addr_len) catch {};
                }
            }.run, .{negative_pc});
            defer negative_thread.join();

            var positive_pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer positive_pc.deinit();

            const positive_impl = try positive_pc.as(Net.UdpConn);
            const positive_port = try positive_impl.boundPort();
            var positive_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(server_pc: PacketConn, ip: [4]u8) void {
                    var req_buf: [512]u8 = undefined;
                    const req = server_pc.readFrom(&req_buf) catch return;

                    lib.Thread.sleep(20 * lib.time.ns_per_ms);

                    var resp_buf: [512]u8 = undefined;
                    const resp_len = buildAResponse(R, req_buf[0..req.bytes_read], ip, &resp_buf) catch return;
                    _ = server_pc.writeTo(resp_buf[0..resp_len], @ptrCast(&req.addr), req.addr_len) catch {};
                }
            }.run, .{ positive_pc, [4]u8{ 11, 22, 33, 44 } });
            defer positive_thread.join();

            var resolver = try initResolver(.{
                .servers = &.{
                    .{ .addr = addr4(negative_port), .protocol = .udp },
                    .{ .addr = addr4(positive_port), .protocol = .udp },
                },
                .mode = .ipv4_only,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            const count = try resolver.lookupHost("negative-first.test", &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            const ip = addrs[0].as4().?;
            try testing.expectEqual([4]u8{ 11, 22, 33, 44 }, ip);
        }

        fn lookupHostReturnsNameNotFoundAfterAllServersReportNXDOMAIN() !void {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();
            var server_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(server_pc: PacketConn) void {
                    var req_buf: [512]u8 = undefined;
                    const req = server_pc.readFrom(&req_buf) catch return;

                    var resp_buf: [512]u8 = undefined;
                    const resp_len = buildErrorResponse(R, req_buf[0..req.bytes_read], 3, &resp_buf) catch return;
                    _ = server_pc.writeTo(resp_buf[0..resp_len], @ptrCast(&req.addr), req.addr_len) catch {};
                }
            }.run, .{pc});
            defer server_thread.join();

            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = addr4(port), .protocol = .udp }},
                .mode = .ipv4_only,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            try testing.expectError(error.NameNotFound, resolver.lookupHost("nxdomain.test", &addrs));
        }

        fn lookupHostReturnsNameNotFoundAfterEmptyUdpSuccessResponses() !void {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();
            var server_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(server_pc: PacketConn) void {
                    var req_buf: [512]u8 = undefined;
                    const req = server_pc.readFrom(&req_buf) catch return;

                    var resp_buf: [512]u8 = undefined;
                    const resp_len = buildEmptySuccessResponse(R, req_buf[0..req.bytes_read], &resp_buf) catch return;
                    _ = server_pc.writeTo(resp_buf[0..resp_len], @ptrCast(&req.addr), req.addr_len) catch {};
                }
            }.run, .{pc});
            defer server_thread.join();

            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = addr4(port), .protocol = .udp }},
                .mode = .ipv4_only,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            try testing.expectError(error.NameNotFound, resolver.lookupHost("empty-udp.test", &addrs));
        }

        fn lookupHostReturnsNameNotFoundAfterEmptyTcpSuccessResponses() !void {
            var listener = try Net.listen(testing.allocator, .{
                .address = addr4(0),
            });
            defer listener.deinit();

            const listener_impl = try listener.as(Net.TcpListener);
            const port = try listenerPort(listener, Net);
            var server_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(ln: *Net.TcpListener) void {
                    var conn = ln.accept() catch return;
                    defer conn.deinit();

                    var req_buf: [512]u8 = undefined;
                    const req = readTcpDnsMessage(conn, &req_buf) catch return;

                    var resp_buf: [512]u8 = undefined;
                    const resp_len = buildEmptySuccessResponse(R, req, &resp_buf) catch return;
                    writeTcpDnsMessage(conn, resp_buf[0..resp_len]) catch return;
                }
            }.run, .{listener_impl});
            defer server_thread.join();

            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = addr4(port), .protocol = .tcp }},
                .mode = .ipv4_only,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            try testing.expectError(error.NameNotFound, resolver.lookupHost("empty-tcp.test", &addrs));
        }

        fn lookupHostResolvesViaTlsServer() !void {
            var listener = try Net.tls.listen(testing.allocator, .{
                .address = addr4(0),
            }, .{
                .certificates = &.{.{
                    .chain = &.{fixtures.self_signed_cert_der[0..]},
                    .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                }},
                .min_version = .tls_1_3,
                .max_version = .tls_1_3,
            });
            defer listener.deinit();

            const port = try tlsListenerPort(listener, Net);
            const listener_impl = try listener.as(Net.tls.Listener);
            var server_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(ln: *Net.tls.Listener, ip: [4]u8) void {
                    var conn = ln.accept() catch return;
                    defer conn.deinit();

                    const tls_conn = conn.as(Net.tls.ServerConn) catch return;
                    tls_conn.handshake() catch return;

                    var req_buf: [512]u8 = undefined;
                    const req = readTcpDnsMessage(conn, &req_buf) catch return;

                    var resp_buf: [512]u8 = undefined;
                    const resp_len = buildAResponse(R, req, ip, &resp_buf) catch return;
                    writeTcpDnsMessage(conn, resp_buf[0..resp_len]) catch return;
                }
            }.run, .{ listener_impl, [4]u8{ 51, 52, 53, 54 } });
            defer server_thread.join();

            var resolver = try initResolver(.{
                .servers = &.{.{
                    .addr = addr4(port),
                    .protocol = .tls,
                    .tls_config = .{
                        .server_name = "example.com",
                        .verification = .self_signed,
                        .min_version = .tls_1_3,
                        .max_version = .tls_1_3,
                    },
                }},
                .mode = .ipv4_only,
                .timeout_ms = 1000,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            const count = try resolver.lookupHost("tls-server.test", &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            const ip = addrs[0].as4().?;
            try testing.expectEqual([4]u8{ 51, 52, 53, 54 }, ip);
        }

        fn lookupHostRejectsTlsServerWithoutConfig() !void {
            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = addr4(853), .protocol = .tls }},
                .mode = .ipv4_only,
                .timeout_ms = 200,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            try testing.expectError(error.InvalidTlsConfig, resolver.lookupHost("missing-tls-config.test", &addrs));
        }

        fn lookupHostResolvesViaDohServer() !void {
            var listener = try Net.tls.listen(testing.allocator, .{
                .address = addr4(0),
            }, .{
                .certificates = &.{.{
                    .chain = &.{fixtures.self_signed_cert_der[0..]},
                    .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                }},
                .min_version = .tls_1_3,
                .max_version = .tls_1_3,
            });
            defer listener.deinit();

            const port = try tlsListenerPort(listener, Net);
            const listener_impl = try listener.as(Net.tls.Listener);
            var server_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(ln: *Net.tls.Listener, ip: [4]u8) void {
                    var conn = ln.accept() catch return;
                    defer conn.deinit();

                    const tls_conn = conn.as(Net.tls.ServerConn) catch return;
                    tls_conn.handshake() catch return;

                    var head_buf: [2048]u8 = undefined;
                    var body_buf: [512]u8 = undefined;
                    const req = readHttpRequest(conn, &head_buf, &body_buf) catch return;
                    if (!std.mem.eql(u8, req.method, "POST")) return;
                    if (!std.mem.eql(u8, req.path, "/dns-query")) return;

                    var dns_buf: [512]u8 = undefined;
                    const dns_len = buildAResponse(R, req.body, ip, &dns_buf) catch return;
                    writeHttpDnsResponse(conn, 200, dns_buf[0..dns_len]) catch return;
                }
            }.run, .{ listener_impl, [4]u8{ 61, 62, 63, 64 } });
            defer server_thread.join();

            var resolver = try initResolver(.{
                .servers = &.{.{
                    .addr = addr4(port),
                    .protocol = .doh,
                    .tls_config = .{
                        .server_name = "example.com",
                        .verification = .self_signed,
                        .min_version = .tls_1_3,
                        .max_version = .tls_1_3,
                    },
                    .doh_path = "/dns-query",
                }},
                .mode = .ipv4_only,
                .timeout_ms = 1000,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            const count = try resolver.lookupHost("doh-server.test", &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            const ip = addrs[0].as4().?;
            try testing.expectEqual([4]u8{ 61, 62, 63, 64 }, ip);
        }

        fn lookupHostRejectsDohServerWithoutConfig() !void {
            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = addr4(443), .protocol = .doh }},
                .mode = .ipv4_only,
                .timeout_ms = 200,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            try testing.expectError(error.InvalidTlsConfig, resolver.lookupHost("missing-doh-config.test", &addrs));
        }

        fn lookupHostReturnsPartialUdpDualStackResult() !void {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();
            var server_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(server_pc: PacketConn, ip: [4]u8) void {
                    var handled: usize = 0;
                    while (handled < 2) : (handled += 1) {
                        var req_buf: [512]u8 = undefined;
                        const req = server_pc.readFrom(&req_buf) catch return;
                        const req_pkt = req_buf[0..req.bytes_read];
                        const qtype = queryTypeFromRequest(req_pkt) catch return;

                        var resp_buf: [512]u8 = undefined;
                        const resp_len = switch (qtype) {
                            R.QTYPE_A => buildAResponse(R, req_pkt, ip, &resp_buf) catch return,
                            R.QTYPE_AAAA => buildEmptySuccessResponse(R, req_pkt, &resp_buf) catch return,
                            else => return,
                        };
                        _ = server_pc.writeTo(resp_buf[0..resp_len], @ptrCast(&req.addr), req.addr_len) catch {};
                    }
                }
            }.run, .{ pc, [4]u8{ 21, 22, 23, 24 } });
            defer server_thread.join();

            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = addr4(port), .protocol = .udp }},
                .mode = .ipv4_and_ipv6,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            const count = try resolver.lookupHost("partial-udp.test", &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            const ip = addrs[0].as4().?;
            try testing.expectEqual([4]u8{ 21, 22, 23, 24 }, ip);
        }

        fn lookupHostReturnsPartialUdpDualStackResultAfterServfail() !void {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();
            var server_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(server_pc: PacketConn, ip: [4]u8) void {
                    var handled: usize = 0;
                    while (handled < 2) : (handled += 1) {
                        var req_buf: [512]u8 = undefined;
                        const req = server_pc.readFrom(&req_buf) catch return;
                        const req_pkt = req_buf[0..req.bytes_read];
                        const qtype = queryTypeFromRequest(req_pkt) catch return;

                        var resp_buf: [512]u8 = undefined;
                        const resp_len = switch (qtype) {
                            R.QTYPE_A => buildAResponse(R, req_pkt, ip, &resp_buf) catch return,
                            R.QTYPE_AAAA => buildErrorResponse(R, req_pkt, 2, &resp_buf) catch return,
                            else => return,
                        };
                        _ = server_pc.writeTo(resp_buf[0..resp_len], @ptrCast(&req.addr), req.addr_len) catch {};
                    }
                }
            }.run, .{ pc, [4]u8{ 25, 26, 27, 28 } });
            defer server_thread.join();

            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = addr4(port), .protocol = .udp }},
                .mode = .ipv4_and_ipv6,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            const count = try resolver.lookupHost("servfail-partial-udp.test", &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            const ip = addrs[0].as4().?;
            try testing.expectEqual([4]u8{ 25, 26, 27, 28 }, ip);
        }

        fn lookupHostUdpServfailAndEmptySuccessReturnsTimeout() !void {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();
            var server_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(server_pc: PacketConn) void {
                    var handled: usize = 0;
                    while (handled < 2) : (handled += 1) {
                        var req_buf: [512]u8 = undefined;
                        const req = server_pc.readFrom(&req_buf) catch return;
                        const req_pkt = req_buf[0..req.bytes_read];
                        const qtype = queryTypeFromRequest(req_pkt) catch return;

                        var resp_buf: [512]u8 = undefined;
                        const resp_len = switch (qtype) {
                            R.QTYPE_A => buildErrorResponse(R, req_pkt, 2, &resp_buf) catch return,
                            R.QTYPE_AAAA => buildEmptySuccessResponse(R, req_pkt, &resp_buf) catch return,
                            else => return,
                        };
                        _ = server_pc.writeTo(resp_buf[0..resp_len], @ptrCast(&req.addr), req.addr_len) catch {};
                    }
                }
            }.run, .{pc});
            defer server_thread.join();

            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = addr4(port), .protocol = .udp }},
                .mode = .ipv4_and_ipv6,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            try testing.expectError(error.Timeout, resolver.lookupHost("servfail-empty-udp.test", &addrs));
        }

        fn lookupHostResolvesViaIpv6UdpServer() !void {
            const loopback = addr6("::1", 0);

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = loopback,
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort6();
            const server_addr = loopback.withPort(port);

            var server_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(server_pc: PacketConn, ip: [4]u8) void {
                    var req_buf: [512]u8 = undefined;
                    const req = server_pc.readFrom(&req_buf) catch return;

                    var resp_buf: [512]u8 = undefined;
                    const resp_len = buildAResponse(R, req_buf[0..req.bytes_read], ip, &resp_buf) catch return;
                    _ = server_pc.writeTo(resp_buf[0..resp_len], @ptrCast(&req.addr), req.addr_len) catch {};
                }
            }.run, .{ pc, [4]u8{ 41, 42, 43, 44 } });
            defer server_thread.join();

            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = server_addr, .protocol = .udp }},
                .mode = .ipv4_only,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            const count = try resolver.lookupHost("ipv6-server.test", &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            const ip = addrs[0].as4().?;
            try testing.expectEqual([4]u8{ 41, 42, 43, 44 }, ip);
        }

        fn lookupHostMatchesOutOfOrderTcpResponsesById() !void {
            const ipv6 = [16]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

            var listener = try Net.listen(testing.allocator, .{
                .address = addr4(0),
            });
            defer listener.deinit();

            const listener_impl = try listener.as(Net.TcpListener);
            const port = try listenerPort(listener, Net);
            var server_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(ln: *Net.TcpListener, ip4: [4]u8, ip6: [16]u8) void {
                    var conn = ln.accept() catch return;
                    defer conn.deinit();

                    var req1_buf: [512]u8 = undefined;
                    const req1 = readTcpDnsMessage(conn, &req1_buf) catch return;
                    var req2_buf: [512]u8 = undefined;
                    const req2 = readTcpDnsMessage(conn, &req2_buf) catch return;

                    var resp1_buf: [512]u8 = undefined;
                    const resp1_len = switch (queryTypeFromRequest(req1) catch return) {
                        R.QTYPE_A => buildAResponse(R, req1, ip4, &resp1_buf) catch return,
                        R.QTYPE_AAAA => buildAaaaResponse(R, req1, ip6, &resp1_buf) catch return,
                        else => return,
                    };

                    var resp2_buf: [512]u8 = undefined;
                    const resp2_len = switch (queryTypeFromRequest(req2) catch return) {
                        R.QTYPE_A => buildAResponse(R, req2, ip4, &resp2_buf) catch return,
                        R.QTYPE_AAAA => buildAaaaResponse(R, req2, ip6, &resp2_buf) catch return,
                        else => return,
                    };

                    writeTcpDnsMessage(conn, resp2_buf[0..resp2_len]) catch return;
                    writeTcpDnsMessage(conn, resp1_buf[0..resp1_len]) catch return;
                }
            }.run, .{ listener_impl, [4]u8{ 31, 32, 33, 34 }, ipv6 });
            defer server_thread.join();

            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = addr4(port), .protocol = .tcp }},
                .mode = .ipv4_and_ipv6,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            const count = try resolver.lookupHost("reordered-tcp.test", &addrs);
            try testing.expectEqual(@as(usize, 2), count);

            var saw_ipv4 = false;
            var saw_ipv6 = false;
            for (addrs[0..count]) |addr| {
                if (addr.is4()) {
                    if (lib.meta.eql(addr.as4().?, [4]u8{ 31, 32, 33, 34 })) saw_ipv4 = true;
                    continue;
                }
                if (addr.is6()) {
                    if (lib.meta.eql(addr.as16().?, ipv6)) saw_ipv6 = true;
                }
            }

            try testing.expect(saw_ipv4);
            try testing.expect(saw_ipv6);
        }

        fn lookupHostWaitBlocksUntilSlowWorkerCleanup() !void {
            const BoolAtomic = lib.atomic.Value(bool);

            const SlowServer = struct {
                listener: net_mod.Listener,
                accepted: BoolAtomic = BoolAtomic.init(false),
                release: BoolAtomic = BoolAtomic.init(false),
            };

            var slow_server = SlowServer{
                .listener = try Net.listen(testing.allocator, .{
                    .address = addr4(0),
                }),
            };
            defer slow_server.listener.deinit();

            const slow_port = try listenerPort(slow_server.listener, Net);
            var slow_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(server: *SlowServer) void {
                    var conn = server.listener.accept() catch return;
                    defer conn.deinit();

                    server.accepted.store(true, .release);
                    while (!server.release.load(.acquire)) {
                        lib.Thread.sleep(lib.time.ns_per_ms);
                    }
                }
            }.run, .{&slow_server});
            errdefer slow_thread.join();
            errdefer slow_server.release.store(true, .release);

            var fast_pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer fast_pc.deinit();

            const fast_impl = try fast_pc.as(Net.UdpConn);
            const fast_port = try fast_impl.boundPort();
            var fast_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(pc: PacketConn, accepted: *BoolAtomic, ip: [4]u8) void {
                    var req_buf: [512]u8 = undefined;
                    const req = pc.readFrom(&req_buf) catch return;

                    var waited_ms: u32 = 0;
                    while (!accepted.load(.acquire) and waited_ms < 200) : (waited_ms += 1) {
                        lib.Thread.sleep(lib.time.ns_per_ms);
                    }

                    var resp_buf: [512]u8 = undefined;
                    const resp_len = buildAResponse(R, req_buf[0..req.bytes_read], ip, &resp_buf) catch return;
                    _ = pc.writeTo(resp_buf[0..resp_len], @ptrCast(&req.addr), req.addr_len) catch {};
                }
            }.run, .{ fast_pc, &slow_server.accepted, [4]u8{ 10, 20, 30, 40 } });
            errdefer fast_thread.join();
            errdefer fast_pc.close();

            var resolver = try initResolver(.{
                .servers = &.{
                    .{ .addr = addr4(slow_port), .protocol = .tcp },
                    .{ .addr = addr4(fast_port), .protocol = .udp },
                },
                .mode = .ipv4_only,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            const count = try resolver.lookupHost("wait.test", &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            const ip = addrs[0].as4().?;
            try testing.expectEqual([4]u8{ 10, 20, 30, 40 }, ip);

            try waitForTrue(lib, &slow_server.accepted, 200);

            var wait_done = BoolAtomic.init(false);
            var wait_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(r: *R, done: *BoolAtomic) void {
                    r.wait();
                    done.store(true, .release);
                }
            }.run, .{ &resolver, &wait_done });
            errdefer slow_server.release.store(true, .release);
            errdefer wait_thread.join();

            lib.Thread.sleep(10 * lib.time.ns_per_ms);
            try testing.expect(!wait_done.load(.acquire));

            slow_server.release.store(true, .release);
            try waitForTrue(lib, &wait_done, 500);
            wait_thread.join();
            fast_thread.join();
            slow_thread.join();
        }

        fn lookupHostContextReturnsCanceled() !void {
            const Context = context_mod.make(lib);
            var context = try Context.init(testing.allocator);
            defer context.deinit();

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();

            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = addr4(port), .protocol = .udp }},
                .mode = .ipv4_only,
                .timeout_ms = 50,
                .attempts = 1,
            });
            defer resolver.deinit();

            var cancel_ctx = try context.withCancel(context.background());
            defer cancel_ctx.deinit();
            cancel_ctx.cancel();

            var addrs: [4]Addr = undefined;
            try testing.expectError(error.Canceled, resolver.lookupHostContext(cancel_ctx, "canceled.test", &addrs));
        }

        fn lookupHostContextReturnsDeadlineExceeded() !void {
            const Context = context_mod.make(lib);
            var context = try Context.init(testing.allocator);
            defer context.deinit();

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();

            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = addr4(port), .protocol = .udp }},
                .mode = .ipv4_only,
                .timeout_ms = 50,
                .attempts = 1,
            });
            defer resolver.deinit();

            var timeout_ctx = try context.withTimeout(context.background(), 5 * lib.time.ns_per_ms);
            defer timeout_ctx.deinit();

            var addrs: [4]Addr = undefined;
            try testing.expectError(error.DeadlineExceeded, resolver.lookupHostContext(timeout_ctx, "deadline.test", &addrs));
        }

        fn lookupHostContextReturnsCustomCause() !void {
            const Context = context_mod.make(lib);
            var context = try Context.init(testing.allocator);
            defer context.deinit();

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();

            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = addr4(port), .protocol = .udp }},
                .mode = .ipv4_only,
                .timeout_ms = 50,
                .attempts = 1,
            });
            defer resolver.deinit();

            var cancel_ctx = try context.withCancel(context.background());
            defer cancel_ctx.deinit();

            var cancel_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(cc: *context_mod.Context, l: type) void {
                    l.Thread.sleep(5 * l.time.ns_per_ms);
                    cc.cancelWithCause(error.BrokenPipe);
                }
            }.run, .{ &cancel_ctx, lib });
            defer cancel_thread.join();

            var addrs: [4]Addr = undefined;
            try testing.expectError(error.BrokenPipe, resolver.lookupHostContext(cancel_ctx, "custom-cause.test", &addrs));
        }

        fn lookupHostReturnsClosedAfterDeinitStarts() !void {
            const BoolAtomic = lib.atomic.Value(bool);

            const SlowServer = struct {
                listener: net_mod.Listener,
                accepted: BoolAtomic = BoolAtomic.init(false),
                release: BoolAtomic = BoolAtomic.init(false),
            };

            const LookupThread = struct {
                resolver: *R,
                done: *BoolAtomic,
                addrs: *[4]Addr,
            };

            var slow_server = SlowServer{
                .listener = try Net.listen(testing.allocator, .{
                    .address = addr4(0),
                }),
            };
            defer slow_server.listener.deinit();

            const slow_port = try listenerPort(slow_server.listener, Net);
            var slow_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(server: *SlowServer) void {
                    var conn = server.listener.accept() catch return;
                    defer conn.deinit();

                    server.accepted.store(true, .release);
                    while (!server.release.load(.acquire)) {
                        lib.Thread.sleep(lib.time.ns_per_ms);
                    }
                }
            }.run, .{&slow_server});
            errdefer slow_thread.join();
            errdefer slow_server.release.store(true, .release);

            var resolver = try initResolver(.{
                .servers = &.{.{ .addr = addr4(slow_port), .protocol = .tcp }},
                .mode = .ipv4_only,
                .timeout_ms = 1000,
                .attempts = 1,
            });
            var resolver_owned = true;
            errdefer if (resolver_owned) resolver.deinit();

            var first_addrs: [4]Addr = undefined;
            var first_lookup_done = BoolAtomic.init(false);
            var lookup_state = LookupThread{
                .resolver = &resolver,
                .done = &first_lookup_done,
                .addrs = &first_addrs,
            };
            var lookup_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(state: *LookupThread) void {
                    _ = state.resolver.lookupHost("closed.test", state.addrs) catch {};
                    state.done.store(true, .release);
                }
            }.run, .{&lookup_state});
            errdefer slow_server.release.store(true, .release);
            errdefer lookup_thread.join();

            try waitForTrue(lib, &slow_server.accepted, 200);

            var deinit_done = BoolAtomic.init(false);
            var deinit_thread = try lib.Thread.spawn(test_spawn_config, struct {
                fn run(r: *R, done: *BoolAtomic) void {
                    r.deinit();
                    done.store(true, .release);
                }
            }.run, .{ &resolver, &deinit_done });
            resolver_owned = false;
            errdefer slow_server.release.store(true, .release);
            errdefer deinit_thread.join();

            try waitUntilDeiniting(lib, &resolver, 200);

            var second_addrs: [4]Addr = undefined;
            try testing.expectError(error.Closed, resolver.lookupHost("closed-again.test", &second_addrs));
            try testing.expect(!deinit_done.load(.acquire));

            slow_server.release.store(true, .release);
            try waitForTrue(lib, &first_lookup_done, 500);
            try waitForTrue(lib, &deinit_done, 500);
            lookup_thread.join();
            deinit_thread.join();
            slow_thread.join();
        }
    };

    try Runner.optionsDefaults();
    try Runner.serverProtocolConfig();
    try Runner.lookupHostIgnoresEarlyNXDOMAINWhenLaterServerSucceeds();
    try Runner.lookupHostReturnsNameNotFoundAfterAllServersReportNXDOMAIN();
    try Runner.lookupHostReturnsNameNotFoundAfterEmptyUdpSuccessResponses();
    try Runner.lookupHostReturnsNameNotFoundAfterEmptyTcpSuccessResponses();
    try Runner.lookupHostResolvesViaTlsServer();
    try Runner.lookupHostRejectsTlsServerWithoutConfig();
    try Runner.lookupHostResolvesViaDohServer();
    try Runner.lookupHostRejectsDohServerWithoutConfig();
    try Runner.lookupHostReturnsPartialUdpDualStackResult();
    try Runner.lookupHostReturnsPartialUdpDualStackResultAfterServfail();
    try Runner.lookupHostUdpServfailAndEmptySuccessReturnsTimeout();
    try Runner.lookupHostResolvesViaIpv6UdpServer();
    try Runner.lookupHostMatchesOutOfOrderTcpResponsesById();
    try Runner.lookupHostWaitBlocksUntilSlowWorkerCleanup();
    try Runner.lookupHostContextReturnsCanceled();
    try Runner.lookupHostContextReturnsDeadlineExceeded();
    try Runner.lookupHostContextReturnsCustomCause();
    try Runner.lookupHostReturnsClosedAfterDeinitStarts();
}

fn buildAResponse(comptime R: type, req: []const u8, ip: [4]u8, out: *[512]u8) !usize {
    var pos = try beginResponse(req, 0x8180, 1, out);
    if (pos + 16 > out.len) return error.InvalidResponse;

    out[pos] = 0xC0;
    out[pos + 1] = 0x0C;
    pos += 2;
    writeU16(out, &pos, R.QTYPE_A);
    writeU16(out, &pos, R.QCLASS_IN);
    writeU32(out, &pos, 300);
    writeU16(out, &pos, 4);
    @memcpy(out[pos..][0..4], &ip);
    pos += 4;
    return pos;
}

fn buildAaaaResponse(comptime R: type, req: []const u8, ip: [16]u8, out: *[512]u8) !usize {
    var pos = try beginResponse(req, 0x8180, 1, out);
    if (pos + 28 > out.len) return error.InvalidResponse;

    out[pos] = 0xC0;
    out[pos + 1] = 0x0C;
    pos += 2;
    writeU16(out, &pos, R.QTYPE_AAAA);
    writeU16(out, &pos, R.QCLASS_IN);
    writeU32(out, &pos, 300);
    writeU16(out, &pos, 16);
    @memcpy(out[pos..][0..16], &ip);
    pos += 16;
    return pos;
}

fn buildEmptySuccessResponse(comptime R: type, req: []const u8, out: *[512]u8) !usize {
    _ = R;
    return beginResponse(req, 0x8180, 0, out);
}

fn buildErrorResponse(comptime R: type, req: []const u8, rcode: u4, out: *[512]u8) !usize {
    _ = R;
    return beginResponse(req, 0x8180 | @as(u16, rcode), 0, out);
}

fn beginResponse(req: []const u8, flags: u16, ancount: u16, out: *[512]u8) !usize {
    if (req.len < 12) return error.InvalidResponse;

    var pos: usize = 0;
    writeU16(out, &pos, readU16(req[0..2]));
    writeU16(out, &pos, flags);
    writeU16(out, &pos, 1);
    writeU16(out, &pos, ancount);
    writeU16(out, &pos, 0);
    writeU16(out, &pos, 0);

    const question = req[12..];
    if (pos + question.len > out.len) return error.InvalidResponse;
    @memcpy(out[pos..][0..question.len], question);
    pos += question.len;
    return pos;
}

fn queryTypeFromRequest(req: []const u8) !u16 {
    if (req.len < 4) return error.InvalidResponse;
    return readU16(req[req.len - 4 ..][0..2]);
}

fn readTcpDnsMessage(conn: Conn, buf: *[512]u8) ![]const u8 {
    var c = conn;
    var len_buf: [2]u8 = undefined;
    try io.readFull(@TypeOf(c), &c, &len_buf);
    const msg_len = readU16(&len_buf);
    if (msg_len > buf.len) return error.InvalidResponse;
    try io.readFull(@TypeOf(c), &c, buf[0..msg_len]);
    return buf[0..msg_len];
}

fn writeTcpDnsMessage(conn: Conn, msg: []const u8) !void {
    var c = conn;
    if (msg.len > 512) return error.InvalidResponse;

    var frame: [514]u8 = undefined;
    frame[0] = @truncate(msg.len >> 8);
    frame[1] = @truncate(msg.len);
    @memcpy(frame[2..][0..msg.len], msg);
    try io.writeAll(@TypeOf(c), &c, frame[0 .. 2 + msg.len]);
}

const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
};

fn readHttpRequest(conn: Conn, head_buf: *[2048]u8, body_buf: *[512]u8) !HttpRequest {
    var c = conn;
    var head_len: usize = 0;
    var head_end: ?usize = null;

    while (head_end == null) {
        if (head_len >= head_buf.len) return error.InvalidResponse;
        const n = try c.read(head_buf[head_len..]);
        if (n == 0) return error.InvalidResponse;
        head_len += n;
        head_end = std.mem.indexOf(u8, head_buf[0..head_len], "\r\n\r\n");
    }

    const header_bytes = head_end.? + 4;
    const parsed = try parseHttpRequestHead(head_buf[0..header_bytes]);
    if (parsed.content_length > body_buf.len) return error.InvalidResponse;

    const prefetched_body = head_len - header_bytes;
    if (prefetched_body > parsed.content_length) return error.InvalidResponse;
    @memcpy(body_buf[0..prefetched_body], head_buf[header_bytes..head_len]);
    if (prefetched_body < parsed.content_length) {
        try io.readFull(@TypeOf(c), &c, body_buf[prefetched_body..parsed.content_length]);
    }

    return .{
        .method = parsed.method,
        .path = parsed.path,
        .body = body_buf[0..parsed.content_length],
    };
}

fn parseHttpRequestHead(head: []const u8) !struct {
    method: []const u8,
    path: []const u8,
    content_length: usize,
} {
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.InvalidResponse;
    const request_line = head[0..line_end];
    const sp1 = std.mem.indexOfScalar(u8, request_line, ' ') orelse return error.InvalidResponse;
    const rest = request_line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidResponse;

    var content_length: usize = 0;
    var offset = line_end + 2;
    while (offset <= head.len) {
        const next_end_rel = std.mem.indexOf(u8, head[offset..], "\r\n") orelse return error.InvalidResponse;
        const line = head[offset .. offset + next_end_rel];
        offset += next_end_rel + 2;
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidResponse;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidResponse;
        }
    }

    return .{
        .method = request_line[0..sp1],
        .path = rest[0..sp2],
        .content_length = content_length,
    };
}

fn writeHttpDnsResponse(conn: Conn, status_code: u16, body: []const u8) !void {
    var c = conn;
    var head_buf: [256]u8 = undefined;
    const status_text = switch (status_code) {
        200 => "OK",
        404 => "Not Found",
        else => "Unexpected",
    };
    const head = try std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/dns-message\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status_code, status_text, body.len },
    );
    try io.writeAll(@TypeOf(c), &c, head);
    try io.writeAll(@TypeOf(c), &c, body);
}

fn writeU32(out: *[512]u8, pos: *usize, value: u32) void {
    out[pos.*] = @truncate(value >> 24);
    out[pos.* + 1] = @truncate(value >> 16);
    out[pos.* + 2] = @truncate(value >> 8);
    out[pos.* + 3] = @truncate(value);
    pos.* += 4;
}

fn writeU16(buf: *[512]u8, pos: *usize, val: u16) void {
    buf[pos.*] = @truncate(val >> 8);
    buf[pos.* + 1] = @truncate(val);
    pos.* += 2;
}

fn readU16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

fn waitForTrue(comptime lib: type, flag: *lib.atomic.Value(bool), timeout_ms: u64) !void {
    var elapsed_ms: u64 = 0;
    while (elapsed_ms < timeout_ms) : (elapsed_ms += 1) {
        if (flag.load(.acquire)) return;
        lib.Thread.sleep(lib.time.ns_per_ms);
    }
    return error.TimeoutWaitingForFlag;
}

fn waitUntilDeiniting(comptime lib: type, resolver: anytype, timeout_ms: u64) !void {
    var elapsed_ms: u64 = 0;
    while (elapsed_ms < timeout_ms) : (elapsed_ms += 1) {
        resolver.mutex.lock();
        const deiniting = resolver.deiniting;
        resolver.mutex.unlock();
        if (deiniting) return;
        lib.Thread.sleep(lib.time.ns_per_ms);
    }
    return error.TimeoutWaitingForDeinit;
}
