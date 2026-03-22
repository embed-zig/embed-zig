//! UDP test runner — integration tests for net.Make(lib) UDP path.
//!
//! Tests listenPacket (PacketConn), connected UDP (Conn), and as() downcast.
//!
//! Usage:
//!   try @import("net/test_runner/udp.zig").run(lib);

const net = @import("../../net.zig");
const PacketConn = net.PacketConn;
const Conn = net.Conn;

pub fn run(comptime lib: type) !void {
    const Net = net.Make(lib);
    const Addr = lib.net.Address;
    const testing = lib.testing;

    const Runner = struct {
        fn udpIpv4ListenPacket() !void {
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

        fn udpIpv6ListenPacket() !void {
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

        fn udpBoundPortRejectsIpv6Sockets() !void {
            const loopback = comptime Addr.parseIp6("::1", 0) catch unreachable;

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = loopback,
            });
            defer pc.deinit();

            const udp_impl = try pc.as(Net.UdpConn);
            try testing.expectError(error.AddressFamilyMismatch, udp_impl.boundPort());
        }

        fn udpBoundPort6RejectsIpv4Sockets() !void {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer pc.deinit();

            const udp_impl = try pc.as(Net.UdpConn);
            try testing.expectError(error.AddressFamilyMismatch, udp_impl.boundPort6());
        }

        fn udpReadTimeout() !void {
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

        fn udpPacketConnAsDowncast() !void {
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

        fn udpConnAsDowncast() !void {
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

    try Runner.udpIpv4ListenPacket();
    try Runner.udpIpv6ListenPacket();
    try Runner.udpBoundPortRejectsIpv6Sockets();
    try Runner.udpBoundPort6RejectsIpv4Sockets();
    try Runner.udpReadTimeout();
    try Runner.udpPacketConnAsDowncast();
    try Runner.udpConnAsDowncast();
}
