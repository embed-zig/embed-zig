//! Resolver fake test runner — unit tests and local fake-DNS integration tests.
//!
//! Uses only local loopback servers, so it can run in environments without
//! public network access and can be invoked directly from platform runners.
//!
//! Usage:
//!   try @import("net/test_runner/resolver_fake.zig").run(lib);

const net_mod = @import("../../net.zig");
const resolver_mod = @import("../Resolver.zig");
const Conn = net_mod.Conn;

pub fn run(comptime lib: type) !void {
    const R = resolver_mod.Resolver(lib);
    const Net = net_mod.Make(lib);
    const Addr = lib.net.Address;
    const PacketConn = net_mod.PacketConn;
    const testing = lib.testing;
    const log = lib.log.scoped(.resolver_fake);

    const Runner = struct {
        fn buildQueryRoundTrip() !void {
            var buf: [512]u8 = undefined;
            const len = try R.buildQuery(&buf, "example.com", R.QTYPE_A, 0x1234);

            try testing.expectEqual(@as(u16, 0x1234), R.readU16(buf[0..2]));
            try testing.expect(len > 12);

            try testing.expectEqual(@as(u8, 7), buf[12]);
            try testing.expectEqualStrings("example", buf[13..20]);
            try testing.expectEqual(@as(u8, 3), buf[20]);
            try testing.expectEqualStrings("com", buf[21..24]);
            try testing.expectEqual(@as(u8, 0), buf[24]);
        }

        fn parseResponseARecord() !void {
            var pkt: [512]u8 = @splat(0);
            var pos: usize = 0;

            R.writeU16(&pkt, &pos, 0xABCD);
            R.writeU16(&pkt, &pos, 0x8180);
            R.writeU16(&pkt, &pos, 1);
            R.writeU16(&pkt, &pos, 1);
            R.writeU16(&pkt, &pos, 0);
            R.writeU16(&pkt, &pos, 0);

            pkt[pos] = 7;
            pos += 1;
            @memcpy(pkt[pos..][0..7], "example");
            pos += 7;
            pkt[pos] = 3;
            pos += 1;
            @memcpy(pkt[pos..][0..3], "com");
            pos += 3;
            pkt[pos] = 0;
            pos += 1;
            R.writeU16(&pkt, &pos, R.QTYPE_A);
            R.writeU16(&pkt, &pos, R.QCLASS_IN);

            pkt[pos] = 0xC0;
            pkt[pos + 1] = 0x0C;
            pos += 2;
            R.writeU16(&pkt, &pos, R.QTYPE_A);
            R.writeU16(&pkt, &pos, R.QCLASS_IN);
            R.writeU16(&pkt, &pos, 0);
            R.writeU16(&pkt, &pos, 300);
            R.writeU16(&pkt, &pos, 4);
            pkt[pos] = 93;
            pkt[pos + 1] = 184;
            pkt[pos + 2] = 216;
            pkt[pos + 3] = 34;
            pos += 4;

            var addrs: [4]Addr = undefined;
            const count = try R.parseResponse(pkt[0..pos], R.QTYPE_A, &addrs);
            try testing.expectEqual(@as(usize, 1), count);

            const ip: [4]u8 = @bitCast(addrs[0].in.sa.addr);
            try testing.expectEqual([4]u8{ 93, 184, 216, 34 }, ip);
        }

        fn parseResponseAaaaRecord() !void {
            var pkt: [512]u8 = @splat(0);
            var pos: usize = 0;

            R.writeU16(&pkt, &pos, 0x5678);
            R.writeU16(&pkt, &pos, 0x8180);
            R.writeU16(&pkt, &pos, 1);
            R.writeU16(&pkt, &pos, 1);
            R.writeU16(&pkt, &pos, 0);
            R.writeU16(&pkt, &pos, 0);

            pkt[pos] = 4;
            pos += 1;
            @memcpy(pkt[pos..][0..4], "test");
            pos += 4;
            pkt[pos] = 7;
            pos += 1;
            @memcpy(pkt[pos..][0..7], "example");
            pos += 7;
            pkt[pos] = 0;
            pos += 1;
            R.writeU16(&pkt, &pos, R.QTYPE_AAAA);
            R.writeU16(&pkt, &pos, R.QCLASS_IN);

            pkt[pos] = 0xC0;
            pkt[pos + 1] = 0x0C;
            pos += 2;
            R.writeU16(&pkt, &pos, R.QTYPE_AAAA);
            R.writeU16(&pkt, &pos, R.QCLASS_IN);
            R.writeU16(&pkt, &pos, 0);
            R.writeU16(&pkt, &pos, 600);
            R.writeU16(&pkt, &pos, 16);

            const ipv6_bytes = [16]u8{ 0x26, 0x06, 0x28, 0x00, 0x02, 0x20, 0x00, 0x01, 0x02, 0x48, 0x18, 0x93, 0x25, 0xc8, 0x19, 0x46 };
            @memcpy(pkt[pos..][0..16], &ipv6_bytes);
            pos += 16;

            var addrs: [4]Addr = undefined;
            const count = try R.parseResponse(pkt[0..pos], R.QTYPE_AAAA, &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            try testing.expectEqual(ipv6_bytes, addrs[0].in6.sa.addr);
        }

        fn optionsDefaults() !void {
            var r = try R.init(testing.allocator, .{});
            defer r.deinit();
            try testing.expectEqual(@as(u32, 1000), r.options.timeout_ms);
            try testing.expectEqual(@as(u32, 2), r.options.attempts);
            try testing.expectEqual(R.QueryMode.ipv4_only, r.options.mode);
            try testing.expectEqual(@as(usize, 4), r.options.servers.len);
        }

        fn serverProtocolConfig() !void {
            const s1 = R.Server.init(R.dns.ali.v4_1, .udp);
            const s2 = R.Server.init(R.dns.ali.v4_2, .tls);
            try testing.expectEqual(R.Protocol.udp, s1.protocol);
            try testing.expectEqual(R.Protocol.tls, s2.protocol);
        }

        fn lookupHostIgnoresEarlyNXDOMAINWhenLaterServerSucceeds() !void {
            var negative_pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer negative_pc.deinit();

            const negative_impl = try negative_pc.as(Net.UdpConn.Inner);
            const negative_port = try negative_impl.boundPort();
            var negative_thread = try lib.Thread.spawn(.{}, struct {
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
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer positive_pc.deinit();

            const positive_impl = try positive_pc.as(Net.UdpConn.Inner);
            const positive_port = try positive_impl.boundPort();
            var positive_thread = try lib.Thread.spawn(.{}, struct {
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

            var resolver = try R.init(testing.allocator, .{
                .servers = &.{
                    .{ .addr = Addr.initIp4(.{ 127, 0, 0, 1 }, negative_port), .protocol = .udp },
                    .{ .addr = Addr.initIp4(.{ 127, 0, 0, 1 }, positive_port), .protocol = .udp },
                },
                .mode = .ipv4_only,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            const count = try resolver.lookupHost("negative-first.test", &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            const ip: [4]u8 = @bitCast(addrs[0].in.sa.addr);
            try testing.expectEqual([4]u8{ 11, 22, 33, 44 }, ip);
        }

        fn lookupHostReturnsNameNotFoundAfterAllServersReportNXDOMAIN() !void {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn.Inner);
            const port = try impl.boundPort();
            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn run(server_pc: PacketConn) void {
                    var req_buf: [512]u8 = undefined;
                    const req = server_pc.readFrom(&req_buf) catch return;

                    var resp_buf: [512]u8 = undefined;
                    const resp_len = buildErrorResponse(R, req_buf[0..req.bytes_read], 3, &resp_buf) catch return;
                    _ = server_pc.writeTo(resp_buf[0..resp_len], @ptrCast(&req.addr), req.addr_len) catch {};
                }
            }.run, .{pc});
            defer server_thread.join();

            var resolver = try R.init(testing.allocator, .{
                .servers = &.{.{ .addr = Addr.initIp4(.{ 127, 0, 0, 1 }, port), .protocol = .udp }},
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
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn.Inner);
            const port = try impl.boundPort();
            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn run(server_pc: PacketConn) void {
                    var req_buf: [512]u8 = undefined;
                    const req = server_pc.readFrom(&req_buf) catch return;

                    var resp_buf: [512]u8 = undefined;
                    const resp_len = buildEmptySuccessResponse(R, req_buf[0..req.bytes_read], &resp_buf) catch return;
                    _ = server_pc.writeTo(resp_buf[0..resp_len], @ptrCast(&req.addr), req.addr_len) catch {};
                }
            }.run, .{pc});
            defer server_thread.join();

            var resolver = try R.init(testing.allocator, .{
                .servers = &.{.{ .addr = Addr.initIp4(.{ 127, 0, 0, 1 }, port), .protocol = .udp }},
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
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer listener.close();

            const port = try listener.port();
            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn run(ln: *Net.TcpListener) void {
                    var conn = ln.accept() catch return;
                    defer conn.deinit();

                    var req_buf: [512]u8 = undefined;
                    const req = readTcpDnsMessage(R, conn, &req_buf) catch return;

                    var resp_buf: [512]u8 = undefined;
                    const resp_len = buildEmptySuccessResponse(R, req, &resp_buf) catch return;
                    writeTcpDnsMessage(conn, resp_buf[0..resp_len]) catch return;
                }
            }.run, .{&listener});
            defer server_thread.join();

            var resolver = try R.init(testing.allocator, .{
                .servers = &.{.{ .addr = Addr.initIp4(.{ 127, 0, 0, 1 }, port), .protocol = .tcp }},
                .mode = .ipv4_only,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            try testing.expectError(error.NameNotFound, resolver.lookupHost("empty-tcp.test", &addrs));
        }

        fn lookupHostReturnsPartialUdpDualStackResult() !void {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn.Inner);
            const port = try impl.boundPort();
            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn run(server_pc: PacketConn, ip: [4]u8) void {
                    var handled: usize = 0;
                    while (handled < 2) : (handled += 1) {
                        var req_buf: [512]u8 = undefined;
                        const req = server_pc.readFrom(&req_buf) catch return;
                        const req_pkt = req_buf[0..req.bytes_read];
                        const qtype = queryTypeFromRequest(R, req_pkt) catch return;

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

            var resolver = try R.init(testing.allocator, .{
                .servers = &.{.{ .addr = Addr.initIp4(.{ 127, 0, 0, 1 }, port), .protocol = .udp }},
                .mode = .ipv4_and_ipv6,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            const count = try resolver.lookupHost("partial-udp.test", &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            const ip: [4]u8 = @bitCast(addrs[0].in.sa.addr);
            try testing.expectEqual([4]u8{ 21, 22, 23, 24 }, ip);
        }

        fn lookupHostReturnsPartialUdpDualStackResultAfterServfail() !void {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn.Inner);
            const port = try impl.boundPort();
            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn run(server_pc: PacketConn, ip: [4]u8) void {
                    var handled: usize = 0;
                    while (handled < 2) : (handled += 1) {
                        var req_buf: [512]u8 = undefined;
                        const req = server_pc.readFrom(&req_buf) catch return;
                        const req_pkt = req_buf[0..req.bytes_read];
                        const qtype = queryTypeFromRequest(R, req_pkt) catch return;

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

            var resolver = try R.init(testing.allocator, .{
                .servers = &.{.{ .addr = Addr.initIp4(.{ 127, 0, 0, 1 }, port), .protocol = .udp }},
                .mode = .ipv4_and_ipv6,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            const count = try resolver.lookupHost("servfail-partial-udp.test", &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            const ip: [4]u8 = @bitCast(addrs[0].in.sa.addr);
            try testing.expectEqual([4]u8{ 25, 26, 27, 28 }, ip);
        }

        fn lookupHostUdpServfailAndEmptySuccessReturnsTimeout() !void {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn.Inner);
            const port = try impl.boundPort();
            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn run(server_pc: PacketConn) void {
                    var handled: usize = 0;
                    while (handled < 2) : (handled += 1) {
                        var req_buf: [512]u8 = undefined;
                        const req = server_pc.readFrom(&req_buf) catch return;
                        const req_pkt = req_buf[0..req.bytes_read];
                        const qtype = queryTypeFromRequest(R, req_pkt) catch return;

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

            var resolver = try R.init(testing.allocator, .{
                .servers = &.{.{ .addr = Addr.initIp4(.{ 127, 0, 0, 1 }, port), .protocol = .udp }},
                .mode = .ipv4_and_ipv6,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            try testing.expectError(error.Timeout, resolver.lookupHost("servfail-empty-udp.test", &addrs));
        }

        fn lookupHostResolvesViaIpv6UdpServer() !void {
            const loopback = comptime Addr.parseIp6("::1", 0) catch unreachable;

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = loopback,
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn.Inner);
            const port = try impl.boundPort6();
            var server_addr = loopback;
            server_addr.setPort(port);

            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn run(server_pc: PacketConn, ip: [4]u8) void {
                    var req_buf: [512]u8 = undefined;
                    const req = server_pc.readFrom(&req_buf) catch return;

                    var resp_buf: [512]u8 = undefined;
                    const resp_len = buildAResponse(R, req_buf[0..req.bytes_read], ip, &resp_buf) catch return;
                    _ = server_pc.writeTo(resp_buf[0..resp_len], @ptrCast(&req.addr), req.addr_len) catch {};
                }
            }.run, .{ pc, [4]u8{ 41, 42, 43, 44 } });
            defer server_thread.join();

            var resolver = try R.init(testing.allocator, .{
                .servers = &.{.{ .addr = server_addr, .protocol = .udp }},
                .mode = .ipv4_only,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            const count = try resolver.lookupHost("ipv6-server.test", &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            const ip: [4]u8 = @bitCast(addrs[0].in.sa.addr);
            try testing.expectEqual([4]u8{ 41, 42, 43, 44 }, ip);
        }

        fn lookupHostMatchesOutOfOrderTcpResponsesById() !void {
            const ipv6 = [16]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

            var listener = try Net.listen(testing.allocator, .{
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer listener.close();

            const port = try listener.port();
            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn run(ln: *Net.TcpListener, ip4: [4]u8, ip6: [16]u8) void {
                    var conn = ln.accept() catch return;
                    defer conn.deinit();

                    var req1_buf: [512]u8 = undefined;
                    const req1 = readTcpDnsMessage(R, conn, &req1_buf) catch return;
                    var req2_buf: [512]u8 = undefined;
                    const req2 = readTcpDnsMessage(R, conn, &req2_buf) catch return;

                    var resp1_buf: [512]u8 = undefined;
                    const resp1_len = switch (queryTypeFromRequest(R, req1) catch return) {
                        R.QTYPE_A => buildAResponse(R, req1, ip4, &resp1_buf) catch return,
                        R.QTYPE_AAAA => buildAaaaResponse(R, req1, ip6, &resp1_buf) catch return,
                        else => return,
                    };

                    var resp2_buf: [512]u8 = undefined;
                    const resp2_len = switch (queryTypeFromRequest(R, req2) catch return) {
                        R.QTYPE_A => buildAResponse(R, req2, ip4, &resp2_buf) catch return,
                        R.QTYPE_AAAA => buildAaaaResponse(R, req2, ip6, &resp2_buf) catch return,
                        else => return,
                    };

                    writeTcpDnsMessage(conn, resp2_buf[0..resp2_len]) catch return;
                    writeTcpDnsMessage(conn, resp1_buf[0..resp1_len]) catch return;
                }
            }.run, .{ &listener, [4]u8{ 31, 32, 33, 34 }, ipv6 });
            defer server_thread.join();

            var resolver = try R.init(testing.allocator, .{
                .servers = &.{.{ .addr = Addr.initIp4(.{ 127, 0, 0, 1 }, port), .protocol = .tcp }},
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
                switch (addr.any.family) {
                    lib.posix.AF.INET => {
                        const ip4: [4]u8 = @bitCast(addr.in.sa.addr);
                        if (lib.meta.eql(ip4, [4]u8{ 31, 32, 33, 34 })) saw_ipv4 = true;
                    },
                    lib.posix.AF.INET6 => {
                        if (lib.meta.eql(addr.in6.sa.addr, ipv6)) saw_ipv6 = true;
                    },
                    else => {},
                }
            }

            try testing.expect(saw_ipv4);
            try testing.expect(saw_ipv6);
        }

        fn lookupHostWaitBlocksUntilSlowWorkerCleanup() !void {
            const BoolAtomic = lib.atomic.Value(bool);

            const SlowServer = struct {
                listener: Net.TcpListener,
                accepted: BoolAtomic = BoolAtomic.init(false),
                release: BoolAtomic = BoolAtomic.init(false),
            };

            var slow_server = SlowServer{
                .listener = try Net.listen(testing.allocator, .{
                    .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
                }),
            };
            defer slow_server.listener.close();

            const slow_port = try slow_server.listener.port();
            var slow_thread = try lib.Thread.spawn(.{}, struct {
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
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer fast_pc.deinit();

            const fast_impl = try fast_pc.as(Net.UdpConn.Inner);
            const fast_port = try fast_impl.boundPort();
            var fast_thread = try lib.Thread.spawn(.{}, struct {
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

            var resolver = try R.init(testing.allocator, .{
                .servers = &.{
                    .{ .addr = Addr.initIp4(.{ 127, 0, 0, 1 }, slow_port), .protocol = .tcp },
                    .{ .addr = Addr.initIp4(.{ 127, 0, 0, 1 }, fast_port), .protocol = .udp },
                },
                .mode = .ipv4_only,
                .timeout_ms = 500,
                .attempts = 1,
            });
            defer resolver.deinit();

            var addrs: [4]Addr = undefined;
            const count = try resolver.lookupHost("wait.test", &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            const ip: [4]u8 = @bitCast(addrs[0].in.sa.addr);
            try testing.expectEqual([4]u8{ 10, 20, 30, 40 }, ip);

            try waitForTrue(lib, &slow_server.accepted, 200);

            var wait_done = BoolAtomic.init(false);
            var wait_thread = try lib.Thread.spawn(.{}, struct {
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

        fn lookupHostReturnsClosedAfterDeinitStarts() !void {
            const BoolAtomic = lib.atomic.Value(bool);

            const SlowServer = struct {
                listener: Net.TcpListener,
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
                    .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
                }),
            };
            defer slow_server.listener.close();

            const slow_port = try slow_server.listener.port();
            var slow_thread = try lib.Thread.spawn(.{}, struct {
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

            var resolver = try R.init(testing.allocator, .{
                .servers = &.{.{ .addr = Addr.initIp4(.{ 127, 0, 0, 1 }, slow_port), .protocol = .tcp }},
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
            var lookup_thread = try lib.Thread.spawn(.{}, struct {
                fn run(state: *LookupThread) void {
                    _ = state.resolver.lookupHost("closed.test", state.addrs) catch {};
                    state.done.store(true, .release);
                }
            }.run, .{&lookup_state});
            errdefer slow_server.release.store(true, .release);
            errdefer lookup_thread.join();

            try waitForTrue(lib, &slow_server.accepted, 200);

            var deinit_done = BoolAtomic.init(false);
            var deinit_thread = try lib.Thread.spawn(.{}, struct {
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

    log.info("=== resolver fake test_runner start ===", .{});
    try Runner.buildQueryRoundTrip();
    try Runner.parseResponseARecord();
    try Runner.parseResponseAaaaRecord();
    try Runner.optionsDefaults();
    try Runner.serverProtocolConfig();
    try Runner.lookupHostIgnoresEarlyNXDOMAINWhenLaterServerSucceeds();
    try Runner.lookupHostReturnsNameNotFoundAfterAllServersReportNXDOMAIN();
    try Runner.lookupHostReturnsNameNotFoundAfterEmptyUdpSuccessResponses();
    try Runner.lookupHostReturnsNameNotFoundAfterEmptyTcpSuccessResponses();
    try Runner.lookupHostReturnsPartialUdpDualStackResult();
    try Runner.lookupHostReturnsPartialUdpDualStackResultAfterServfail();
    try Runner.lookupHostUdpServfailAndEmptySuccessReturnsTimeout();
    try Runner.lookupHostResolvesViaIpv6UdpServer();
    try Runner.lookupHostMatchesOutOfOrderTcpResponsesById();
    try Runner.lookupHostWaitBlocksUntilSlowWorkerCleanup();
    try Runner.lookupHostReturnsClosedAfterDeinitStarts();
    log.info("=== resolver fake test_runner done ===", .{});
}

fn buildAResponse(comptime R: type, req: []const u8, ip: [4]u8, out: *[512]u8) !usize {
    var pos = try beginResponse(R, req, 0x8180, 1, out);
    if (pos + 16 > out.len) return error.InvalidResponse;

    out[pos] = 0xC0;
    out[pos + 1] = 0x0C;
    pos += 2;
    R.writeU16(out, &pos, R.QTYPE_A);
    R.writeU16(out, &pos, R.QCLASS_IN);
    writeU32(out, &pos, 300);
    R.writeU16(out, &pos, 4);
    @memcpy(out[pos..][0..4], &ip);
    pos += 4;
    return pos;
}

fn buildAaaaResponse(comptime R: type, req: []const u8, ip: [16]u8, out: *[512]u8) !usize {
    var pos = try beginResponse(R, req, 0x8180, 1, out);
    if (pos + 28 > out.len) return error.InvalidResponse;

    out[pos] = 0xC0;
    out[pos + 1] = 0x0C;
    pos += 2;
    R.writeU16(out, &pos, R.QTYPE_AAAA);
    R.writeU16(out, &pos, R.QCLASS_IN);
    writeU32(out, &pos, 300);
    R.writeU16(out, &pos, 16);
    @memcpy(out[pos..][0..16], &ip);
    pos += 16;
    return pos;
}

fn buildEmptySuccessResponse(comptime R: type, req: []const u8, out: *[512]u8) !usize {
    return beginResponse(R, req, 0x8180, 0, out);
}

fn buildErrorResponse(comptime R: type, req: []const u8, rcode: u4, out: *[512]u8) !usize {
    return beginResponse(R, req, 0x8180 | @as(u16, rcode), 0, out);
}

fn beginResponse(comptime R: type, req: []const u8, flags: u16, ancount: u16, out: *[512]u8) !usize {
    if (req.len < 12) return error.InvalidResponse;

    var pos: usize = 0;
    R.writeU16(out, &pos, R.readU16(req[0..2]));
    R.writeU16(out, &pos, flags);
    R.writeU16(out, &pos, 1);
    R.writeU16(out, &pos, ancount);
    R.writeU16(out, &pos, 0);
    R.writeU16(out, &pos, 0);

    const question = req[12..];
    if (pos + question.len > out.len) return error.InvalidResponse;
    @memcpy(out[pos..][0..question.len], question);
    pos += question.len;
    return pos;
}

fn queryTypeFromRequest(comptime R: type, req: []const u8) !u16 {
    if (req.len < 4) return error.InvalidResponse;
    return R.readU16(req[req.len - 4 ..][0..2]);
}

fn readTcpDnsMessage(comptime R: type, conn: Conn, buf: *[512]u8) ![]const u8 {
    var len_buf: [2]u8 = undefined;
    try conn.readAll(&len_buf);
    const msg_len = R.readU16(&len_buf);
    if (msg_len > buf.len) return error.InvalidResponse;
    try conn.readAll(buf[0..msg_len]);
    return buf[0..msg_len];
}

fn writeTcpDnsMessage(conn: Conn, msg: []const u8) !void {
    if (msg.len > 512) return error.InvalidResponse;

    var frame: [514]u8 = undefined;
    frame[0] = @truncate(msg.len >> 8);
    frame[1] = @truncate(msg.len);
    @memcpy(frame[2..][0..msg.len], msg);
    try conn.writeAll(frame[0 .. 2 + msg.len]);
}

fn writeU32(out: *[512]u8, pos: *usize, value: u32) void {
    out[pos.*] = @truncate(value >> 24);
    out[pos.* + 1] = @truncate(value >> 16);
    out[pos.* + 2] = @truncate(value >> 8);
    out[pos.* + 3] = @truncate(value);
    pos.* += 4;
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
