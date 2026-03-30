//! fd packet test runner — validates the internal non-blocking packet layer.

const context_mod = @import("context");
const embed = @import("embed");
const testing_api = @import("testing");
const fd_mod = @import("../fd.zig");
const netip = @import("../netip.zig");
const sockaddr_mod = @import("../fd/SockAddr.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            runImpl(lib, t, allocator) catch |err| {
                t.logErrorf("fd_packet runner failed: {}", .{err});
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
    const Context = context_mod.make(lib);
    const Packet = fd_mod.Packet(lib);
    const AddrPort = netip.AddrPort;
    const Addr = netip.Addr;
    const SockAddr = sockaddr_mod.SockAddr(lib);
    const Thread = lib.Thread;
    const posix = lib.posix;
    const testing = struct {
        pub var allocator: lib.mem.Allocator = undefined;
        pub const expect = lib.testing.expect;
        pub const expectEqual = lib.testing.expectEqual;
        pub const expectEqualStrings = lib.testing.expectEqualStrings;
        pub const expectError = lib.testing.expectError;
    };
    testing.allocator = alloc;

    const Runner = struct {
        fn bindLoopback(addr: AddrPort) !Packet {
            const encoded = try SockAddr.encode(addr);
            var packet = try Packet.initSocket(encoded.family);
            errdefer packet.deinit();
            try posix.bind(packet.fd, @ptrCast(&encoded.storage), encoded.len);
            return packet;
        }

        fn localAddr(packet: *const Packet) !AddrPort {
            var bound: posix.sockaddr.storage = undefined;
            var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            try posix.getsockname(packet.fd, @ptrCast(&bound), &bound_len);
            return switch (@as(*const posix.sockaddr, @ptrCast(&bound)).family) {
                posix.AF.INET => blk: {
                    const in: *const posix.sockaddr.in = @ptrCast(@alignCast(&bound));
                    const addr_bytes: [4]u8 = @bitCast(in.addr);
                    break :blk AddrPort.from4(addr_bytes, lib.mem.bigToNative(u16, in.port));
                },
                posix.AF.INET6 => blk: {
                    const in6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(&bound));
                    var ip = Addr.from16(in6.addr);
                    if (in6.scope_id != 0) {
                        var scope_buf: [10]u8 = undefined;
                        const scope = try lib.fmt.bufPrint(&scope_buf, "{d}", .{in6.scope_id});
                        ip.zone_len = @intCast(scope.len);
                        @memcpy(ip.zone[0..scope.len], scope);
                    }
                    break :blk AddrPort.init(ip, lib.mem.bigToNative(u16, in6.port));
                },
                else => unreachable,
            };
        }

        fn expectFromAddrPort(result: Packet.ReadFromResult, expected_port: u16) !void {
            const sa: *const posix.sockaddr = @ptrCast(&result.addr);
            try testing.expectEqual(posix.AF.INET, sa.family);
            const in: *const posix.sockaddr.in = @ptrCast(@alignCast(&result.addr));
            try testing.expectEqual(expected_port, lib.mem.bigToNative(u16, in.port));
        }

        fn expectFromAddrPort6(result: Packet.ReadFromResult, expected_port: u16) !void {
            const sa: *const posix.sockaddr = @ptrCast(&result.addr);
            try testing.expectEqual(posix.AF.INET6, sa.family);
            const in6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(&result.addr));
            try testing.expectEqual(expected_port, lib.mem.bigToNative(u16, in6.port));
        }

        fn skipIfConnectDidNotPend(err: anyerror) anyerror!void {
            switch (err) {
                error.AccessDenied,
                error.PermissionDenied,
                error.AddressInUse,
                error.AddressNotAvailable,
                error.AddressFamilyNotSupported,
                error.ConnectionRefused,
                error.NetworkUnreachable,
                error.ConnectionTimedOut,
                error.ConnectionResetByPeer,
                error.FileNotFound,
                error.SystemResources,
                error.ConnectFailed,
                => return error.SkipZigTest,
                else => return err,
            }
        }

        fn packetIpv4Loopback() !void {
            var receiver = try bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
            defer receiver.deinit();
            var sender = try bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
            defer sender.deinit();

            const dest = try localAddr(&receiver);
            const src = try localAddr(&sender);
            const sent = try sender.writeTo("hello packet", dest);
            try testing.expectEqual(@as(usize, 12), sent);

            var buf: [64]u8 = undefined;
            const recv = try receiver.readFrom(&buf);
            try testing.expectEqualStrings("hello packet", buf[0..recv.bytes_read]);
            try expectFromAddrPort(recv, src.port());
        }

        fn packetIpv6Loopback() !void {
            const loopback = AddrPort.init(comptime Addr.mustParse("::1"), 0);

            var receiver = try bindLoopback(loopback);
            defer receiver.deinit();
            var sender = try bindLoopback(loopback);
            defer sender.deinit();

            const dest = try localAddr(&receiver);
            const src = try localAddr(&sender);
            const sent = try sender.writeTo("udp6", dest);
            try testing.expectEqual(@as(usize, 4), sent);

            var buf: [16]u8 = undefined;
            const recv = try receiver.readFrom(&buf);
            try testing.expectEqualStrings("udp6", buf[0..recv.bytes_read]);
            try expectFromAddrPort6(recv, src.port());
        }

        fn packetConnectedReadWrite() !void {
            var server = try bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
            defer server.deinit();
            var client = try bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
            defer client.deinit();

            const server_addr = try localAddr(&server);
            const client_addr = try localAddr(&client);
            try client.connect(server_addr);
            try server.connect(client_addr);

            _ = try client.write("ping");
            var buf: [16]u8 = undefined;
            const n1 = try server.read(&buf);
            try testing.expectEqualStrings("ping", buf[0..n1]);

            _ = try server.write("pong");
            const n2 = try client.read(&buf);
            try testing.expectEqualStrings("pong", buf[0..n2]);
        }

        fn packetConnectContextLoopback() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var server = try bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
            defer server.deinit();
            var client = try bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
            defer client.deinit();

            const server_addr = try localAddr(&server);
            try client.connectContext(ctx_api.background(), server_addr);

            _ = try client.write("ctx");

            var buf: [16]u8 = undefined;
            const recv = try server.readFrom(&buf);
            try testing.expectEqualStrings("ctx", buf[0..recv.bytes_read]);

            const n = try server.writeTo("ok", try localAddr(&client));
            try testing.expectEqual(@as(usize, 2), n);

            const ack_len = try client.read(&buf);
            try testing.expectEqualStrings("ok", buf[0..ack_len]);
        }

        fn packetConnectContextCanceledBeforeStart() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var ctx = try ctx_api.withCancel(ctx_api.background());
            defer ctx.deinit();
            ctx.cancel();

            var packet = try Packet.initSocket(posix.AF.INET);
            defer packet.deinit();

            try testing.expectError(
                error.Canceled,
                packet.connectContext(ctx, AddrPort.from4(.{ 127, 0, 0, 1 }, 1)),
            );
        }

        fn packetConnectContextDeadlineExceededBeforeStart() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() - 1 * lib.time.ns_per_ms);
            defer ctx.deinit();

            var packet = try Packet.initSocket(posix.AF.INET);
            defer packet.deinit();

            try testing.expectError(
                error.DeadlineExceeded,
                packet.connectContext(ctx, AddrPort.from4(.{ 127, 0, 0, 1 }, 1)),
            );
        }

        fn packetConnectContextCanceledDuringConnect() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var ctx = try ctx_api.withCancel(ctx_api.background());
            defer ctx.deinit();

            var packet = try Packet.initSocket(posix.AF.INET);
            defer packet.deinit();

            const cancel_thread = try Thread.spawn(.{}, struct {
                fn run(cancel_ctx: context_mod.Context, comptime thread_lib: type) void {
                    thread_lib.Thread.sleep(40 * thread_lib.time.ns_per_ms);
                    cancel_ctx.cancel();
                }
            }.run, .{ ctx, lib });
            defer cancel_thread.join();

            packet.connectContext(ctx, AddrPort.from4(.{ 203, 0, 113, 1 }, 9)) catch |err| switch (err) {
                error.Canceled => return,
                else => return skipIfConnectDidNotPend(err),
            };

            // UDP connect may complete synchronously on some hosts because there
            // is no handshake to force an in-progress state.
            return error.SkipZigTest;
        }

        fn packetConnectContextDeadlineExceededDuringConnect() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() + 40 * lib.time.ns_per_ms);
            defer ctx.deinit();

            var packet = try Packet.initSocket(posix.AF.INET);
            defer packet.deinit();

            packet.connectContext(ctx, AddrPort.from4(.{ 203, 0, 113, 1 }, 9)) catch |err| switch (err) {
                error.DeadlineExceeded => return,
                else => return skipIfConnectDidNotPend(err),
            };

            // UDP connect may complete synchronously on some hosts because there
            // is no handshake to force an in-progress state.
            return error.SkipZigTest;
        }

        fn packetPreservesDatagramBoundaries() !void {
            var receiver = try bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
            defer receiver.deinit();
            var sender = try bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
            defer sender.deinit();

            const dest = try localAddr(&receiver);
            _ = try sender.writeTo("abcdef", dest);
            _ = try sender.writeTo("xy", dest);

            var first: [8]u8 = undefined;
            const r1 = try receiver.readFrom(&first);
            try testing.expectEqualStrings("abcdef", first[0..r1.bytes_read]);

            var second: [8]u8 = undefined;
            const r2 = try receiver.readFrom(&second);
            try testing.expectEqualStrings("xy", second[0..r2.bytes_read]);
        }

        fn packetReadDeadlineTimesOut() !void {
            var packet = try bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
            defer packet.deinit();

            packet.setReadDeadline(lib.time.milliTimestamp() + 20);
            var buf: [8]u8 = undefined;
            try testing.expectError(error.TimedOut, packet.readFrom(&buf));
        }

        fn packetReadDeadlineClearAllowsLaterRead() !void {
            var receiver = try bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
            defer receiver.deinit();
            var sender = try bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
            defer sender.deinit();

            receiver.setReadDeadline(lib.time.milliTimestamp() + 20);
            var buf: [8]u8 = undefined;
            try testing.expectError(error.TimedOut, receiver.readFrom(&buf));

            receiver.setReadDeadline(null);
            const dest = try localAddr(&receiver);
            const writer = try Thread.spawn(.{}, struct {
                fn run(packet: *Packet, addr: AddrPort, comptime thread_lib: type) void {
                    thread_lib.Thread.sleep(30 * thread_lib.time.ns_per_ms);
                    _ = packet.writeTo("after", addr) catch {};
                }
            }.run, .{ &sender, dest, lib });
            defer writer.join();

            const recv = try receiver.readFrom(&buf);
            try testing.expectEqualStrings("after", buf[0..recv.bytes_read]);
        }

        fn packetFullDuplexStreaming() !void {
            var a = try bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
            defer a.deinit();
            var b = try bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
            defer b.deinit();

            const a_addr = try localAddr(&a);
            const b_addr = try localAddr(&b);
            try a.connect(b_addr);
            try b.connect(a_addr);

            a.setDeadline(lib.time.milliTimestamp() + 1500);
            b.setDeadline(lib.time.milliTimestamp() + 1500);

            const a_writer = try Thread.spawn(.{}, struct {
                fn run(packet: *Packet) void {
                    var i: usize = 0;
                    while (i < 64) : (i += 1) {
                        var msg: [16]u8 = undefined;
                        const len = makeIndexedMessage(&msg, 'a', i);
                        _ = packet.write(msg[0..len]) catch return;
                    }
                }
            }.run, .{&a});
            defer a_writer.join();

            const b_writer = try Thread.spawn(.{}, struct {
                fn run(packet: *Packet) void {
                    var i: usize = 0;
                    while (i < 64) : (i += 1) {
                        var msg: [16]u8 = undefined;
                        const len = makeIndexedMessage(&msg, 'b', i);
                        _ = packet.write(msg[0..len]) catch return;
                    }
                }
            }.run, .{&b});
            defer b_writer.join();

            var a_recv: usize = 0;
            var b_recv: usize = 0;
            var buf: [16]u8 = undefined;
            while (a_recv < 64 or b_recv < 64) {
                if (a_recv < 64) {
                    const n = try a.read(&buf);
                    try testing.expectEqual(@as(u8, 'b'), buf[0]);
                    try testing.expect(n >= 2);
                    a_recv += 1;
                }
                if (b_recv < 64) {
                    const n = try b.read(&buf);
                    try testing.expectEqual(@as(u8, 'a'), buf[0]);
                    try testing.expect(n >= 2);
                    b_recv += 1;
                }
            }
        }

        fn packetOpsAfterCloseReturnClosed() !void {
            var packet = try Packet.initSocket(posix.AF.INET);
            packet.close();

            var buf: [1]u8 = undefined;
            try testing.expectError(error.Closed, packet.read(&buf));
            try testing.expectError(error.Closed, packet.readFrom(&buf));
            try testing.expectError(error.Closed, packet.write("x"));
            try testing.expectError(error.Closed, packet.writeTo("x", AddrPort.from4(.{ 127, 0, 0, 1 }, 1)));
            try testing.expectError(error.Closed, packet.connect(AddrPort.from4(.{ 127, 0, 0, 1 }, 1)));
        }

        fn packetCloseIsIdempotent() !void {
            var packet = try Packet.initSocket(posix.AF.INET);
            packet.close();
            packet.close();

            var buf: [1]u8 = undefined;
            try testing.expectError(error.Closed, packet.readFrom(&buf));
        }

        fn makeIndexedMessage(buf: []u8, prefix: u8, index: usize) usize {
            buf[0] = prefix;
            var tmp = index;
            var digits: [10]u8 = undefined;
            var n: usize = 0;
            while (true) {
                digits[n] = @as(u8, @intCast(tmp % 10)) + '0';
                n += 1;
                tmp /= 10;
                if (tmp == 0) break;
            }
            var out: usize = 1;
            var i = n;
            while (i > 0) {
                i -= 1;
                buf[out] = digits[i];
                out += 1;
            }
            return out;
        }
    };

    try Runner.packetIpv4Loopback();
    try Runner.packetIpv6Loopback();
    try Runner.packetConnectedReadWrite();
    try Runner.packetConnectContextLoopback();
    try Runner.packetConnectContextCanceledBeforeStart();
    try Runner.packetConnectContextDeadlineExceededBeforeStart();
    Runner.packetConnectContextCanceledDuringConnect() catch |err| switch (err) {
        error.SkipZigTest => {},
        else => return err,
    };
    Runner.packetConnectContextDeadlineExceededDuringConnect() catch |err| switch (err) {
        error.SkipZigTest => {},
        else => return err,
    };
    try Runner.packetPreservesDatagramBoundaries();
    try Runner.packetReadDeadlineTimesOut();
    try Runner.packetReadDeadlineClearAllowsLaterRead();
    try Runner.packetFullDuplexStreaming();
    try Runner.packetOpsAfterCloseReturnClosed();
    try Runner.packetCloseIsIdempotent();
}
