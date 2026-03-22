//! TCP test runner — integration tests for net.Make(lib) TCP path.
//!
//! Tests dial, listen, accept, read/write over loopback for both IPv4 and IPv6.
//!
//! Usage:
//!   try @import("net/test_runner/tcp.zig").run(lib);

const io = @import("io");
const net = @import("../../net.zig");

pub fn run(comptime lib: type) !void {
    const Net = net.Make(lib);
    const Addr = lib.net.Address;
    const Thread = lib.Thread;
    const testing = lib.testing;

    const Runner = struct {
        const Mutex = Thread.Mutex;
        const Condition = Thread.Condition;

        const StartGate = struct {
            mutex: Mutex = .{},
            cond: Condition = .{},
            ready: usize = 0,
            target: usize,

            fn init(target: usize) @This() {
                return .{ .target = target };
            }

            fn wait(self: *@This()) void {
                self.mutex.lock();
                defer self.mutex.unlock();

                self.ready += 1;
                if (self.ready == self.target) {
                    self.cond.broadcast();
                    return;
                }
                while (self.ready < self.target) self.cond.wait(&self.mutex);
            }
        };

        const ReadyCounter = struct {
            mutex: Mutex = .{},
            cond: Condition = .{},
            ready: usize = 0,
            target: usize,

            fn init(target: usize) @This() {
                return .{ .target = target };
            }

            fn markReady(self: *@This()) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.ready += 1;
                self.cond.broadcast();
            }

            fn waitUntilReady(self: *@This()) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                while (self.ready < self.target) self.cond.wait(&self.mutex);
            }
        };

        fn fillPattern(buf: []u8, seed: u8) void {
            for (buf, 0..) |*byte, i| {
                byte.* = @truncate((i * 131 + seed) % 251);
            }
        }

        fn listenerPort(ln: net.Listener, comptime NetNs: type) !u16 {
            const typed = try ln.as(NetNs.TcpListener);
            return typed.port();
        }

        fn tcpIpv4DialAndListen() !void {
            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const bound_port = try listenerPort(ln, Net);

            var cc = try Net.dial(testing.allocator, .tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, bound_port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            const msg = "hello net.dial";
            try io.writeAll(@TypeOf(cc), &cc, msg);

            var buf: [64]u8 = undefined;
            try io.readFull(@TypeOf(ac), &ac, buf[0..msg.len]);
            try testing.expectEqualStrings(msg, buf[0..msg.len]);

            try io.writeAll(@TypeOf(ac), &ac, "pong");
            try io.readFull(@TypeOf(cc), &cc, buf[0..4]);
            try testing.expectEqualStrings("pong", buf[0..4]);
        }

        fn tcpIpv6DialAndListen() !void {
            const loopback_v6 = comptime Addr.parseIp6("::1", 0) catch unreachable;

            var ln = try Net.listen(testing.allocator, .{ .address = loopback_v6 });
            defer ln.deinit();

            const bound_port = try listenerPort(ln, Net);

            var dial_addr = loopback_v6;
            dial_addr.setPort(bound_port);

            var cc = try Net.dial(testing.allocator, .tcp, dial_addr);
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            const msg = "hello net.dial v6";
            try io.writeAll(@TypeOf(cc), &cc, msg);

            var buf: [64]u8 = undefined;
            try io.readFull(@TypeOf(ac), &ac, buf[0..msg.len]);
            try testing.expectEqualStrings(msg, buf[0..msg.len]);

            try io.writeAll(@TypeOf(ac), &ac, "v6ok");
            try io.readFull(@TypeOf(cc), &cc, buf[0..4]);
            try testing.expectEqualStrings("v6ok", buf[0..4]);
        }

        fn tcpReadTimeout() !void {
            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);

            var cc = try Net.dial(testing.allocator, .tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            ac.setReadTimeout(1);

            var buf: [64]u8 = undefined;
            const result = ac.read(&buf);
            try testing.expectError(error.TimedOut, result);

            ac.setReadTimeout(null);
            try io.writeAll(@TypeOf(cc), &cc, "after timeout");
            try io.readFull(@TypeOf(ac), &ac, buf[0..13]);
            try testing.expectEqualStrings("after timeout", buf[0..13]);
        }

        fn tcpReadFull() !void {
            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);

            var cc = try Net.dial(testing.allocator, .tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            _ = try cc.write("he");
            _ = try cc.write("llo");

            var buf: [5]u8 = undefined;
            try io.readFull(@TypeOf(ac), &ac, &buf);
            try testing.expectEqualStrings("hello", &buf);
        }

        fn tcpWriteTimeout() !void {
            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);

            var cc = try Net.dial(testing.allocator, .tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            cc.setWriteTimeout(1);

            var big: [65536]u8 = @splat(0x42);
            var timed_out = false;
            for (0..4096) |_| {
                _ = cc.write(&big) catch |err| {
                    if (err == error.TimedOut) {
                        timed_out = true;
                    }
                    break;
                };
            }
            try testing.expect(timed_out);
        }

        fn tcpConnAsDowncast() !void {
            const TcpConnType = @import("../TcpConn.zig").TcpConn(lib);
            const UdpConnType = @import("../UdpConn.zig").UdpConn(lib);

            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);

            var cc = try Net.dial(testing.allocator, .tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            const tcp_impl = try cc.as(TcpConnType);
            try testing.expect(!tcp_impl.closed);
            try testing.expect(tcp_impl.fd != 0);

            try testing.expectError(error.TypeMismatch, cc.as(UdpConnType));
        }

        fn tcpMultipleAccept() !void {
            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);
            const dest = Addr.initIp4(.{ 127, 0, 0, 1 }, port);

            var c1 = try Net.dial(testing.allocator, .tcp, dest);
            defer c1.deinit();
            var a1 = try ln.accept();
            defer a1.deinit();

            var c2 = try Net.dial(testing.allocator, .tcp, dest);
            defer c2.deinit();
            var a2 = try ln.accept();
            defer a2.deinit();

            _ = try c1.write("conn1");
            _ = try c2.write("conn2");

            var buf: [64]u8 = undefined;
            const n1 = try a1.read(buf[0..]);
            try testing.expectEqualStrings("conn1", buf[0..n1]);

            const n2 = try a2.read(buf[0..]);
            try testing.expectEqualStrings("conn2", buf[0..n2]);
        }

        fn tcpConnConcurrentBidirectionalReadWrite() !void {
            const ReadCtx = struct {
                gate: *StartGate,
                conn: net.Conn,
                buf: []u8,
                result: ?anyerror = null,
            };

            const WriteCtx = struct {
                gate: *StartGate,
                conn: net.Conn,
                buf: []const u8,
                result: ?anyerror = null,
            };

            const Worker = struct {
                fn read(ctx: *ReadCtx) void {
                    ctx.gate.wait();
                    io.readFull(@TypeOf(ctx.conn), &ctx.conn, ctx.buf) catch |err| {
                        ctx.result = err;
                    };
                }

                fn write(ctx: *WriteCtx) void {
                    ctx.gate.wait();
                    io.writeAll(@TypeOf(ctx.conn), &ctx.conn, ctx.buf) catch |err| {
                        ctx.result = err;
                    };
                }
            };

            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);
            const dest = Addr.initIp4(.{ 127, 0, 0, 1 }, port);

            var cc = try Net.dial(testing.allocator, .tcp, dest);
            defer cc.deinit();
            var ac = try ln.accept();
            defer ac.deinit();

            cc.setReadTimeout(10_000);
            cc.setWriteTimeout(10_000);
            ac.setReadTimeout(10_000);
            ac.setWriteTimeout(10_000);

            const client_len = 128 * 1024 + 257;
            const server_len = 96 * 1024 + 113;

            const client_payload = try testing.allocator.alloc(u8, client_len);
            defer testing.allocator.free(client_payload);
            fillPattern(client_payload, 17);

            const server_payload = try testing.allocator.alloc(u8, server_len);
            defer testing.allocator.free(server_payload);
            fillPattern(server_payload, 91);

            const client_received = try testing.allocator.alloc(u8, server_len);
            defer testing.allocator.free(client_received);

            const server_received = try testing.allocator.alloc(u8, client_len);
            defer testing.allocator.free(server_received);

            var gate = StartGate.init(4);
            var client_reader = ReadCtx{ .gate = &gate, .conn = cc, .buf = client_received };
            var client_writer = WriteCtx{ .gate = &gate, .conn = cc, .buf = client_payload };
            var server_reader = ReadCtx{ .gate = &gate, .conn = ac, .buf = server_received };
            var server_writer = WriteCtx{ .gate = &gate, .conn = ac, .buf = server_payload };

            var client_reader_thread = try Thread.spawn(.{}, Worker.read, .{&client_reader});
            var client_writer_thread = try Thread.spawn(.{}, Worker.write, .{&client_writer});
            var server_reader_thread = try Thread.spawn(.{}, Worker.read, .{&server_reader});
            var server_writer_thread = try Thread.spawn(.{}, Worker.write, .{&server_writer});
            client_reader_thread.join();
            client_writer_thread.join();
            server_reader_thread.join();
            server_writer_thread.join();

            if (client_reader.result) |err| return err;
            if (client_writer.result) |err| return err;
            if (server_reader.result) |err| return err;
            if (server_writer.result) |err| return err;

            try testing.expectEqualSlices(u8, server_payload, client_received);
            try testing.expectEqualSlices(u8, client_payload, server_received);
        }

        fn tcpListenerConcurrentAccept() !void {
            const client_msg_len = "client1".len;

            const AcceptCtx = struct {
                ready: *ReadyCounter,
                listener: net.Listener,
                result: ?anyerror = null,
                len: usize = 0,
                payload: [16]u8 = [_]u8{0} ** 16,
            };

            const Worker = struct {
                fn accept(ctx: *AcceptCtx) void {
                    ctx.ready.markReady();
                    var conn = ctx.listener.accept() catch |err| {
                        ctx.result = err;
                        return;
                    };
                    defer conn.deinit();

                    conn.setReadTimeout(10_000);
                    conn.setWriteTimeout(10_000);

                    io.readFull(@TypeOf(conn), &conn, ctx.payload[0..client_msg_len]) catch |err| {
                        ctx.result = err;
                        return;
                    };
                    ctx.len = client_msg_len;

                    io.writeAll(@TypeOf(conn), &conn, "ack") catch |err| {
                        ctx.result = err;
                    };
                }
            };

            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);
            const dest = Addr.initIp4(.{ 127, 0, 0, 1 }, port);

            var ready = ReadyCounter.init(2);
            var accept1 = AcceptCtx{ .ready = &ready, .listener = ln };
            var accept2 = AcceptCtx{ .ready = &ready, .listener = ln };

            var t1 = try Thread.spawn(.{}, Worker.accept, .{&accept1});
            var t2 = try Thread.spawn(.{}, Worker.accept, .{&accept2});

            ready.waitUntilReady();

            var c1 = try Net.dial(testing.allocator, .tcp, dest);
            defer c1.deinit();
            var c2 = try Net.dial(testing.allocator, .tcp, dest);
            defer c2.deinit();

            c1.setReadTimeout(10_000);
            c1.setWriteTimeout(10_000);
            c2.setReadTimeout(10_000);
            c2.setWriteTimeout(10_000);

            try io.writeAll(@TypeOf(c1), &c1, "client1");
            try io.writeAll(@TypeOf(c2), &c2, "client2");

            var ack: [3]u8 = undefined;
            try io.readFull(@TypeOf(c1), &c1, &ack);
            try testing.expectEqualStrings("ack", &ack);
            try io.readFull(@TypeOf(c2), &c2, &ack);
            try testing.expectEqualStrings("ack", &ack);

            t1.join();
            t2.join();

            if (accept1.result) |err| return err;
            if (accept2.result) |err| return err;

            const got1 = accept1.payload[0..accept1.len];
            const got2 = accept2.payload[0..accept2.len];
            const ok =
                (lib.mem.eql(u8, got1, "client1") and lib.mem.eql(u8, got2, "client2")) or
                (lib.mem.eql(u8, got1, "client2") and lib.mem.eql(u8, got2, "client1"));
            try testing.expect(ok);
        }
    };

    try Runner.tcpIpv4DialAndListen();
    try Runner.tcpIpv6DialAndListen();
    try Runner.tcpReadTimeout();
    try Runner.tcpReadFull();
    try Runner.tcpWriteTimeout();
    try Runner.tcpConnAsDowncast();
    try Runner.tcpMultipleAccept();
    try Runner.tcpConnConcurrentBidirectionalReadWrite();
    try Runner.tcpListenerConcurrentAccept();
}
