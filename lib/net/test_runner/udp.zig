//! UDP test runner — integration tests for net.Make(lib) UDP path.
//!
//! Tests listenPacket (PacketConn), connected UDP (Conn), and as() downcast.
//!
//! Usage:
//!   const runner = @import("net/test_runner/udp.zig");
//!   test { runner.run(std); }

const net = @import("../../net.zig");
const PacketConn = net.PacketConn;
const Conn = net.Conn;

pub fn run(comptime lib: type) void {
    const Net = net.Make(lib);
    const Addr = lib.net.Address;
    const testing = lib.testing;

    _ = struct {
        test "udp ipv4 listenPacket" {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer pc.deinit();

            const udp_impl = try pc.as(Net.UdpConn);
            const port = try udp_impl.boundPort();
            const dest = Addr.initIp4(.{ 127, 0, 0, 1 }, port);
            _ = try pc.writeTo("hello listenPacket", @ptrCast(&dest.any), dest.getOsSockLen());

            var buf: [64]u8 = undefined;
            const result = try pc.readFrom(&buf);
            try testing.expectEqualStrings("hello listenPacket", buf[0..result.bytes_read]);
        }

        test "udp ipv6 listenPacket" {
            const loopback = comptime Addr.parseIp6("::1", 0) catch unreachable;

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = loopback,
            });
            defer pc.deinit();

            const uc = try pc.as(Net.UdpConn);
            const port = try uc.boundPort6();
            var dest = loopback;
            dest.setPort(port);
            _ = try pc.writeTo("udp v6 listenPacket", @ptrCast(&dest.any), dest.getOsSockLen());

            var buf: [64]u8 = undefined;
            const r = try pc.readFrom(&buf);
            try testing.expectEqualStrings("udp v6 listenPacket", buf[0..r.bytes_read]);
        }

        test "udp read timeout" {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer pc.deinit();

            pc.setReadTimeout(1);

            var buf: [64]u8 = undefined;
            const result = pc.readFrom(&buf);
            try testing.expectError(error.TimedOut, result);

            pc.setReadTimeout(null);

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();
            const dest = Addr.initIp4(.{ 127, 0, 0, 1 }, port);

            _ = try pc.writeTo("after clear", @ptrCast(&dest.any), dest.getOsSockLen());
            const r = try pc.readFrom(&buf);
            try testing.expectEqualStrings("after clear", buf[0..r.bytes_read]);
        }

        test "udp packetConn.as downcast" {
            const TcpConnType = @import("../TcpConn.zig").TcpConn(lib);

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer pc.deinit();

            const udp_impl = try pc.as(Net.UdpConn);
            try testing.expect(!udp_impl.closed);
            try testing.expect(udp_impl.fd != 0);

            try testing.expectError(error.TypeMismatch, pc.as(TcpConnType));
        }

        test "udp connected pair via Conn" {
            const posix = lib.posix;

            const fd_a = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            errdefer posix.close(fd_a);
            const fd_b = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            errdefer posix.close(fd_b);

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

            var ca = try Net.UdpConn.init(testing.allocator, fd_a);
            defer ca.deinit();
            var cb = try Net.UdpConn.init(testing.allocator, fd_b);
            defer cb.deinit();
            const ca_udp = try ca.as(Net.UdpConn);
            const cb_udp = try cb.as(Net.UdpConn);

            try ca_udp.writeAll("via conn vtable");
            var buf: [15]u8 = undefined;
            try cb_udp.readAll(&buf);
            try testing.expectEqualStrings("via conn vtable", &buf);
        }

        test "udp readAll short packet" {
            const posix = lib.posix;

            const fd_a = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            errdefer posix.close(fd_a);
            const fd_b = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            errdefer posix.close(fd_b);

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

            var ca = try Net.UdpConn.init(testing.allocator, fd_a);
            defer ca.deinit();
            var cb = try Net.UdpConn.init(testing.allocator, fd_b);
            defer cb.deinit();
            const ca_udp = try ca.as(Net.UdpConn);
            const cb_udp = try cb.as(Net.UdpConn);

            try ca_udp.writeAll("hi");

            var buf: [3]u8 = undefined;
            try testing.expectError(error.ShortRead, cb_udp.readAll(&buf));
        }

        test "udp readAll empty buffer is no-op" {
            const posix = lib.posix;

            const fd_a = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            errdefer posix.close(fd_a);
            const fd_b = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            errdefer posix.close(fd_b);

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

            var ca = try Net.UdpConn.init(testing.allocator, fd_a);
            defer ca.deinit();
            var cb = try Net.UdpConn.init(testing.allocator, fd_b);
            defer cb.deinit();
            const ca_udp = try ca.as(Net.UdpConn);
            const cb_udp = try cb.as(Net.UdpConn);

            try ca_udp.writeAll("hey");

            var empty: [0]u8 = .{};
            try cb_udp.readAll(&empty);

            var buf: [3]u8 = undefined;
            try cb_udp.readAll(&buf);
            try testing.expectEqualStrings("hey", &buf);
        }

        test "udp conn.as downcast" {
            const posix = lib.posix;
            const TcpConnType = @import("../TcpConn.zig").TcpConn(lib);

            const fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            errdefer posix.close(fd);
            const bind_addr = Addr.initIp4(.{ 127, 0, 0, 1 }, 0);
            try posix.bind(fd, @ptrCast(&bind_addr.any), bind_addr.getOsSockLen());

            var c = try Net.UdpConn.init(testing.allocator, fd);
            defer c.deinit();

            const udp_impl = try c.as(Net.UdpConn);
            try testing.expect(!udp_impl.closed);

            try testing.expectError(error.TypeMismatch, c.as(TcpConnType));
        }

    };
}

test "std_compat" {
    const std = @import("std");
    run(std);
}
