//! UDP test runner — integration tests for net.Make(lib) UDP path.
//!
//! Tests listenPacket, readFrom/writeTo over loopback for both IPv4 and IPv6,
//! plus connected UDP via UdpConn.connectTo + Conn interface.
//!
//! Usage:
//!   const runner = @import("net/test_runner/udp.zig");
//!   test { runner.run(std); }

const net = @import("../../net.zig");

pub fn run(comptime lib: type) void {
    const Net = net.Make(lib);
    const Addr = lib.net.Address;
    const testing = lib.testing;

    _ = struct {
        test "udp ipv4 listenPacket" {
            var uc = try Net.listenPacket(.{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer uc.close();

            const port = try boundPort(uc.fd);
            const dest = Addr.initIp4(.{ 127, 0, 0, 1 }, port);
            _ = try uc.writeTo("hello listenPacket", @ptrCast(&dest.any), dest.getOsSockLen());

            var buf: [64]u8 = undefined;
            const result = try uc.readFrom(&buf);
            try testing.expectEqualStrings("hello listenPacket", buf[0..result.bytes_read]);
        }

        test "udp ipv6 listenPacket" {
            const loopback = comptime Addr.parseIp6("::1", 0) catch unreachable;

            var uc = try Net.listenPacket(.{ .address = loopback });
            defer uc.close();

            const port = try boundPort6(uc.fd);
            var dest = loopback;
            dest.setPort(port);
            _ = try uc.writeTo("udp v6 listenPacket", @ptrCast(&dest.any), dest.getOsSockLen());

            var buf: [64]u8 = undefined;
            const r = try uc.readFrom(&buf);
            try testing.expectEqualStrings("udp v6 listenPacket", buf[0..r.bytes_read]);
        }

        test "udp packetConn vtable" {
            var uc = try Net.listenPacket(.{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer uc.close();

            const port = try boundPort(uc.fd);
            const dest = Addr.initIp4(.{ 127, 0, 0, 1 }, port);

            var pc = uc.packetConn();
            _ = try pc.writeTo("via vtable", @ptrCast(&dest.any), dest.getOsSockLen());

            var buf: [64]u8 = undefined;
            const result = try pc.readFrom(&buf);
            try testing.expectEqualStrings("via vtable", buf[0..result.bytes_read]);
        }

        test "udp read timeout" {
            var uc = try Net.listenPacket(.{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
            defer uc.close();

            uc.setReadTimeout(1);

            var buf: [64]u8 = undefined;
            const result = uc.readFrom(&buf);
            try testing.expectError(error.TimedOut, result);

            uc.setReadTimeout(null);

            const port = try boundPort(uc.fd);
            const dest = Addr.initIp4(.{ 127, 0, 0, 1 }, port);

            _ = try uc.writeTo("after clear", @ptrCast(&dest.any), dest.getOsSockLen());
            const r = try uc.readFrom(&buf);
            try testing.expectEqualStrings("after clear", buf[0..r.bytes_read]);
        }

        test "udp connected pair via Conn" {
            const posix = lib.posix;

            const fd_a = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            const fd_b = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);

            const bind_addr = Addr.initIp4(.{ 127, 0, 0, 1 }, 0);
            try posix.bind(fd_a, @ptrCast(&bind_addr.any), bind_addr.getOsSockLen());
            try posix.bind(fd_b, @ptrCast(&bind_addr.any), bind_addr.getOsSockLen());

            var addr_a: posix.sockaddr.in = undefined;
            var len_a: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            try posix.getsockname(fd_a, @ptrCast(&addr_a), &len_a);

            var addr_b: posix.sockaddr.in = undefined;
            var len_b: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            try posix.getsockname(fd_b, @ptrCast(&addr_b), &len_b);

            try posix.connect(fd_a, @ptrCast(&addr_b), @sizeOf(posix.sockaddr.in));
            try posix.connect(fd_b, @ptrCast(&addr_a), @sizeOf(posix.sockaddr.in));

            var uc_a = Net.UdpConn.init(fd_a);
            defer uc_a.close();
            var uc_b = Net.UdpConn.init(fd_b);
            defer uc_b.close();

            var ca = uc_a.conn();
            var cb = uc_b.conn();

            _ = try ca.write("via conn vtable");
            var buf: [64]u8 = undefined;
            const n = try cb.read(&buf);
            try testing.expectEqualStrings("via conn vtable", buf[0..n]);
        }

        fn boundPort(fd: lib.posix.socket_t) !u16 {
            var bound: lib.posix.sockaddr.in = undefined;
            var bound_len: lib.posix.socklen_t = @sizeOf(lib.posix.sockaddr.in);
            try lib.posix.getsockname(fd, @ptrCast(&bound), &bound_len);
            return lib.mem.bigToNative(u16, bound.port);
        }

        fn boundPort6(fd: lib.posix.socket_t) !u16 {
            var bound: lib.posix.sockaddr.in6 = undefined;
            var bound_len: lib.posix.socklen_t = @sizeOf(lib.posix.sockaddr.in6);
            try lib.posix.getsockname(fd, @ptrCast(&bound), &bound_len);
            return lib.mem.bigToNative(u16, bound.port);
        }
    };
}

test "std_compat" {
    const std = @import("std");
    run(std);
}
