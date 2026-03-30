//! TCP test runner — integration tests for net.make(lib) TCP path.
//!
//! Tests dial, listen, accept, read/write over loopback for both IPv4 and IPv6.
//!
//! Usage:
//!   const runner = @import("net/test_runner/tcp.zig").make(lib);
//!   t.run("net/tcp", runner);

const context_mod = @import("context");
const embed = @import("embed");
const io = @import("io");
const testing_api = @import("testing");
const net = @import("../../net.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            runImpl(lib, t, allocator) catch |err| {
                t.logErrorf("tcp runner failed: {}", .{err});
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
    const Net = net.make(lib);
    const Addr = net.netip.AddrPort;
    const IpAddr = net.netip.Addr;
    const Thread = lib.Thread;
    const testing = struct {
        pub var allocator: lib.mem.Allocator = undefined;
        pub const expect = lib.testing.expect;
        pub const expectEqual = lib.testing.expectEqual;
        pub const expectEqualSlices = lib.testing.expectEqualSlices;
        pub const expectEqualStrings = lib.testing.expectEqualStrings;
        pub const expectError = lib.testing.expectError;
    };
    testing.allocator = alloc;

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

        fn listenerPort(ln: net.Listener, comptime NetNs: type) !u16 {
            const typed = try ln.as(NetNs.TcpListener);
            return typed.port();
        }

        fn addr4(addr: [4]u8, port: u16) Addr {
            return Addr.from4(addr, port);
        }

        fn addr6(text: []const u8, port: u16) !Addr {
            return Addr.init(try IpAddr.parse(text), port);
        }

        fn tcpIpv4DialAndListen() !void {
            var ln = try Net.listen(testing.allocator, .{ .address = addr4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const bound_port = try listenerPort(ln, Net);

            var cc = try Net.dial(testing.allocator, .tcp, addr4(.{ 127, 0, 0, 1 }, bound_port));
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
            const loopback_v6 = try addr6("::1", 0);

            var ln = try Net.listen(testing.allocator, .{ .address = loopback_v6 });
            defer ln.deinit();

            const bound_port = try listenerPort(ln, Net);

            const dial_addr = loopback_v6.withPort(bound_port);

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

        fn tcpDialerDialAndDialContext() !void {
            const Context = context_mod.make(lib);

            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var ln = try Net.listen(testing.allocator, .{ .address = addr4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const bound_port = try listenerPort(ln, Net);
            const d = Net.Dialer.init(testing.allocator, .{});

            var cc = try d.dial(.tcp, addr4(.{ 127, 0, 0, 1 }, bound_port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            const msg = "hello Dialer.dial tcp";
            try io.writeAll(@TypeOf(cc), &cc, msg);

            var buf: [64]u8 = undefined;
            try io.readFull(@TypeOf(ac), &ac, buf[0..msg.len]);
            try testing.expectEqualStrings(msg, buf[0..msg.len]);

            var ctx_conn = try d.dialContext(ctx_api.background(), .tcp, addr4(.{ 127, 0, 0, 1 }, bound_port));
            defer ctx_conn.deinit();

            var ctx_ac = try ln.accept();
            defer ctx_ac.deinit();

            const ctx_msg = "hello dialContext tcp";
            try io.writeAll(@TypeOf(ctx_conn), &ctx_conn, ctx_msg);
            try io.readFull(@TypeOf(ctx_ac), &ctx_ac, buf[0..ctx_msg.len]);
            try testing.expectEqualStrings(ctx_msg, buf[0..ctx_msg.len]);
        }

        fn tcpDialContextCanceledBeforeStart() !void {
            const Context = context_mod.make(lib);

            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var cancel_ctx = try ctx_api.withCancel(ctx_api.background());
            defer cancel_ctx.deinit();
            cancel_ctx.cancel();

            var d = Net.Dialer.init(testing.allocator, .{});
            try testing.expectError(
                error.Canceled,
                d.dialContext(cancel_ctx, .tcp, addr4(.{ 127, 0, 0, 1 }, 1)),
            );
        }

        fn tcpDialContextDeadlineExceededBeforeStart() !void {
            const Context = context_mod.make(lib);

            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var deadline_ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() - 1 * lib.time.ns_per_ms);
            defer deadline_ctx.deinit();

            var d = Net.Dialer.init(testing.allocator, .{});
            try testing.expectError(
                error.DeadlineExceeded,
                d.dialContext(deadline_ctx, .tcp, addr4(.{ 127, 0, 0, 1 }, 1)),
            );
        }

        fn tcpDialContextCanceledDuringConnect() !void {
            const Context = context_mod.make(lib);

            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var cancel_ctx = try ctx_api.withCancel(ctx_api.background());
            defer cancel_ctx.deinit();

            const d = Net.Dialer.init(testing.allocator, .{});
            const cancel_thread = try Thread.spawn(.{}, struct {
                fn run(ctx: context_mod.Context, comptime thread_lib: type) void {
                    thread_lib.Thread.sleep(40 * thread_lib.time.ns_per_ms);
                    ctx.cancel();
                }
            }.run, .{ cancel_ctx, lib });
            defer cancel_thread.join();

            var conn = d.dialContext(cancel_ctx, .tcp, addr4(.{ 203, 0, 113, 1 }, 9)) catch |err| switch (err) {
                error.Canceled => return,
                else => return skipIfConnectDidNotPend(err),
            };
            defer conn.deinit();

            return error.ExpectedCanceledConnect;
        }

        fn tcpDialContextDeadlineExceededDuringConnect() !void {
            const Context = context_mod.make(lib);

            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var deadline_ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() + 40 * lib.time.ns_per_ms);
            defer deadline_ctx.deinit();

            const d = Net.Dialer.init(testing.allocator, .{});
            var conn = d.dialContext(deadline_ctx, .tcp, addr4(.{ 203, 0, 113, 1 }, 9)) catch |err| switch (err) {
                error.DeadlineExceeded => return,
                else => return skipIfConnectDidNotPend(err),
            };
            defer conn.deinit();

            return error.ExpectedDeadlineExceeded;
        }

        fn tcpReadWithCanceledIoContextMapsToTimedOut() !void {
            const Context = context_mod.make(lib);

            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var io_ctx = try ctx_api.withCancel(ctx_api.background());
            defer io_ctx.deinit();

            var ln = try Net.listen(testing.allocator, .{ .address = addr4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);

            var cc = try Net.dial(testing.allocator, .tcp, addr4(.{ 127, 0, 0, 1 }, port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            const accepted = try ac.as(Net.TcpConn);
            accepted.pushIoContext(io_ctx);

            const cancel_thread = try Thread.spawn(.{}, struct {
                fn run(ctx: context_mod.Context, comptime thread_lib: type) void {
                    thread_lib.Thread.sleep(30 * thread_lib.time.ns_per_ms);
                    ctx.cancel();
                }
            }.run, .{ io_ctx, lib });
            defer cancel_thread.join();

            var buf: [16]u8 = undefined;
            try testing.expectError(error.TimedOut, ac.read(&buf));

            accepted.popIoContext();
            try io.writeAll(@TypeOf(cc), &cc, "ok");
            try io.readFull(@TypeOf(ac), &ac, buf[0..2]);
            try testing.expectEqualStrings("ok", buf[0..2]);
        }

        fn tcpReadWithDeadlineIoContextMapsToTimedOut() !void {
            const Context = context_mod.make(lib);

            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var io_ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() + 30 * lib.time.ns_per_ms);
            defer io_ctx.deinit();

            var ln = try Net.listen(testing.allocator, .{ .address = addr4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);

            var cc = try Net.dial(testing.allocator, .tcp, addr4(.{ 127, 0, 0, 1 }, port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            const accepted = try ac.as(Net.TcpConn);
            accepted.pushIoContext(io_ctx);

            var buf: [16]u8 = undefined;
            try testing.expectError(error.TimedOut, ac.read(&buf));

            accepted.popIoContext();
            try io.writeAll(@TypeOf(cc), &cc, "ok");
            try io.readFull(@TypeOf(ac), &ac, buf[0..2]);
            try testing.expectEqualStrings("ok", buf[0..2]);
        }

        fn tcpReadTimeout() !void {
            var ln = try Net.listen(testing.allocator, .{ .address = addr4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);

            var cc = try Net.dial(testing.allocator, .tcp, addr4(.{ 127, 0, 0, 1 }, port));
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
            var ln = try Net.listen(testing.allocator, .{ .address = addr4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);

            var cc = try Net.dial(testing.allocator, .tcp, addr4(.{ 127, 0, 0, 1 }, port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            _ = try cc.write("he");
            _ = try cc.write("llo");

            var buf: [5]u8 = undefined;
            try io.readFull(@TypeOf(ac), &ac, &buf);
            try testing.expectEqualStrings("hello", &buf);
        }

        fn tcpReadReportsEndOfStreamAfterPeerShutdownWrite() !void {
            var ln = try Net.listen(testing.allocator, .{ .address = addr4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);

            var cc = try Net.dial(testing.allocator, .tcp, addr4(.{ 127, 0, 0, 1 }, port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            const accepted = try ac.as(Net.TcpConn);
            try accepted.stream.shutdown(.write);

            cc.setReadTimeout(1_000);

            var buf: [16]u8 = undefined;
            try testing.expectError(error.EndOfStream, cc.read(&buf));
        }

        fn tcpWriteTimeout() !void {
            var ln = try Net.listen(testing.allocator, .{ .address = addr4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);

            var cc = try Net.dial(testing.allocator, .tcp, addr4(.{ 127, 0, 0, 1 }, port));
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

            var ln = try Net.listen(testing.allocator, .{ .address = addr4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);

            var cc = try Net.dial(testing.allocator, .tcp, addr4(.{ 127, 0, 0, 1 }, port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            const tcp_impl = try cc.as(TcpConnType);
            try testing.expect(!tcp_impl.closed);
            try testing.expect(tcp_impl.fd != 0);

            try testing.expectError(error.TypeMismatch, cc.as(UdpConnType));
        }

        fn tcpMultipleAccept() !void {
            var ln = try Net.listen(testing.allocator, .{ .address = addr4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);
            const dest = addr4(.{ 127, 0, 0, 1 }, port);

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

            var ln = try Net.listen(testing.allocator, .{ .address = addr4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);
            const dest = addr4(.{ 127, 0, 0, 1 }, port);

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

            var ln = try Net.listen(testing.allocator, .{ .address = addr4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.deinit();

            const port = try listenerPort(ln, Net);
            const dest = addr4(.{ 127, 0, 0, 1 }, port);

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
    try Runner.tcpDialerDialAndDialContext();
    try Runner.tcpDialContextCanceledBeforeStart();
    try Runner.tcpDialContextDeadlineExceededBeforeStart();
    Runner.tcpDialContextCanceledDuringConnect() catch |err| switch (err) {
        error.SkipZigTest => {},
        else => return err,
    };
    Runner.tcpDialContextDeadlineExceededDuringConnect() catch |err| switch (err) {
        error.SkipZigTest => {},
        else => return err,
    };
    try Runner.tcpReadWithCanceledIoContextMapsToTimedOut();
    try Runner.tcpReadWithDeadlineIoContextMapsToTimedOut();
    try Runner.tcpReadTimeout();
    try Runner.tcpReadFull();
    try Runner.tcpReadReportsEndOfStreamAfterPeerShutdownWrite();
    try Runner.tcpWriteTimeout();
    try Runner.tcpConnAsDowncast();
    try Runner.tcpMultipleAccept();
    try Runner.tcpConnConcurrentBidirectionalReadWrite();
    try Runner.tcpListenerConcurrentAccept();
}
