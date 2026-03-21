//! TCP test runner — integration tests for net.Make(lib) TCP path.
//!
//! Tests dial, listen, accept, read/write over loopback for both IPv4 and IPv6.
//!
//! Usage:
//!   const runner = @import("net/test_runner/tcp.zig");
//!   test { runner.run(std); }

const io = @import("io");
const net = @import("../../net.zig");

pub fn run(comptime lib: type) void {
    const Net = net.Make(lib);
    const Addr = lib.net.Address;
    const testing = lib.testing;

    _ = struct {
        test "tcp ipv4 dial and listen" {
            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.close();

            const bound_port = try ln.port();

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

        test "tcp ipv6 dial and listen" {
            const loopback_v6 = comptime Addr.parseIp6("::1", 0) catch unreachable;

            var ln = try Net.listen(testing.allocator, .{ .address = loopback_v6 });
            defer ln.close();

            const bound_port = try ln.port();

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

        test "tcp read timeout" {
            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.close();

            const port = try ln.port();

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

        test "tcp readFull" {
            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.close();

            const port = try ln.port();

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

        test "tcp write timeout" {
            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.close();

            const port = try ln.port();

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

        test "tcp conn.as downcast" {
            const TcpConnType = @import("../TcpConn.zig").TcpConn(lib);
            const UdpConnType = @import("../UdpConn.zig").UdpConn(lib);

            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.close();

            const port = try ln.port();

            var cc = try Net.dial(testing.allocator, .tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            const tcp_impl = try cc.as(TcpConnType);
            try testing.expect(!tcp_impl.closed);
            try testing.expect(tcp_impl.fd != 0);

            try testing.expectError(error.TypeMismatch, cc.as(UdpConnType));
        }

        test "tcp multiple accept" {
            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.close();

            const port = try ln.port();
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
    };
}

test "std_compat" {
    const std = @import("std");
    run(std);
}
