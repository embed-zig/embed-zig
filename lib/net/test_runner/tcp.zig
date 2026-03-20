//! TCP test runner — integration tests for net.Make(lib) TCP path.
//!
//! Tests dial, listen, accept, read/write over loopback for both IPv4 and IPv6.
//!
//! Usage:
//!   const runner = @import("net/test_runner/tcp.zig");
//!   test { runner.run(std); }

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

            var cc = try Net.dial(testing.allocator, Addr.initIp4(.{ 127, 0, 0, 1 }, bound_port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            const msg = "hello net.dial";
            try cc.writeAll(msg);

            var buf: [64]u8 = undefined;
            try ac.readAll(buf[0..msg.len]);
            try testing.expectEqualStrings(msg, buf[0..msg.len]);

            try ac.writeAll("pong");
            try cc.readAll(buf[0..4]);
            try testing.expectEqualStrings("pong", buf[0..4]);
        }

        test "tcp ipv6 dial and listen" {
            const loopback_v6 = comptime Addr.parseIp6("::1", 0) catch unreachable;

            var ln = try Net.listen(testing.allocator, .{ .address = loopback_v6 });
            defer ln.close();

            const bound_port = try ln.port();

            var dial_addr = loopback_v6;
            dial_addr.setPort(bound_port);

            var cc = try Net.dial(testing.allocator, dial_addr);
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            const msg = "hello net.dial v6";
            try cc.writeAll(msg);

            var buf: [64]u8 = undefined;
            try ac.readAll(buf[0..msg.len]);
            try testing.expectEqualStrings(msg, buf[0..msg.len]);

            try ac.writeAll("v6ok");
            try cc.readAll(buf[0..4]);
            try testing.expectEqualStrings("v6ok", buf[0..4]);
        }

        test "tcp read timeout" {
            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.close();

            const port = try ln.port();

            var cc = try Net.dial(testing.allocator, Addr.initIp4(.{ 127, 0, 0, 1 }, port));
            defer cc.deinit();

            var ac = try ln.accept();
            defer ac.deinit();

            ac.setReadTimeout(1);

            var buf: [64]u8 = undefined;
            const result = ac.read(&buf);
            try testing.expectError(error.TimedOut, result);

            ac.setReadTimeout(null);
            try cc.writeAll("after timeout");
            try ac.readAll(buf[0..13]);
            try testing.expectEqualStrings("after timeout", buf[0..13]);
        }

        test "tcp write timeout" {
            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.close();

            const port = try ln.port();

            var cc = try Net.dial(testing.allocator, Addr.initIp4(.{ 127, 0, 0, 1 }, port));
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

        test "tcp multiple accept" {
            var ln = try Net.listen(testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer ln.close();

            const port = try ln.port();
            const dest = Addr.initIp4(.{ 127, 0, 0, 1 }, port);

            var c1 = try Net.dial(testing.allocator, dest);
            defer c1.deinit();
            var a1 = try ln.accept();
            defer a1.deinit();

            var c2 = try Net.dial(testing.allocator, dest);
            defer c2.deinit();
            var a2 = try ln.accept();
            defer a2.deinit();

            try c1.writeAll("conn1");
            try c2.writeAll("conn2");

            var buf: [64]u8 = undefined;
            try a1.readAll(buf[0..5]);
            try testing.expectEqualStrings("conn1", buf[0..5]);

            try a2.readAll(buf[0..5]);
            try testing.expectEqualStrings("conn2", buf[0..5]);
        }
    };
}

test "std_compat" {
    const std = @import("std");
    run(std);
}
