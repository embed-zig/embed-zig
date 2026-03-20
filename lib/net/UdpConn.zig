//! UdpConn — PacketConn implementation over a UDP socket fd.
//!
//! Internal type used by net.listenPacket and Resolver.
//! Users interact with the type-erased PacketConn interface,
//! or use UdpConn directly for typed access.

const Conn = @import("Conn.zig");
const PacketConn = @import("PacketConn.zig");

pub fn UdpConn(comptime lib: type) type {
    const posix = lib.posix;
    const Allocator = lib.mem.Allocator;

    return struct {
        fd: posix.socket_t,
        allocator: ?Allocator = null,
        closed: bool = false,

        const Self = @This();

        pub fn init(fd: posix.socket_t) Self {
            return .{ .fd = fd };
        }

        /// Read from a connected UDP socket (after connect()).
        pub fn read(self: *Self, buf: []u8) Conn.ReadError!usize {
            if (self.closed) return error.EndOfStream;
            return posix.recv(self.fd, buf, 0) catch |err| return switch (err) {
                error.ConnectionRefused => error.ConnectionRefused,
                error.ConnectionResetByPeer => error.ConnectionReset,
                else => error.Unexpected,
            };
        }

        /// Write to a connected UDP socket (after connect()).
        pub fn write(self: *Self, buf: []const u8) Conn.WriteError!usize {
            if (self.closed) return error.BrokenPipe;
            return posix.send(self.fd, buf, 0) catch |err| return switch (err) {
                error.ConnectionResetByPeer => error.ConnectionReset,
                error.BrokenPipe => error.BrokenPipe,
                else => error.Unexpected,
            };
        }

        /// Connect to a remote address (makes read/write usable without address).
        pub fn connectTo(self: *Self, addr: [*]const u8, addr_len: u32) !void {
            try posix.connect(self.fd, @ptrCast(addr), addr_len);
        }

        pub fn conn(self: *Self) Conn {
            return Conn.init(self);
        }

        pub fn readFrom(self: *Self, buf: []u8) PacketConn.ReadFromError!PacketConn.ReadFromResult {
            if (self.closed) return error.Unexpected;
            var result: PacketConn.ReadFromResult = .{
                .bytes_read = 0,
                .addr = @splat(0),
                .addr_len = @sizeOf(PacketConn.AddrStorage),
            };
            const n = posix.recvfrom(
                self.fd,
                buf,
                0,
                @ptrCast(&result.addr),
                @ptrCast(&result.addr_len),
            ) catch |err| return switch (err) {
                error.WouldBlock => error.WouldBlock,
                error.ConnectionRefused => error.ConnectionRefused,
                else => error.Unexpected,
            };
            result.bytes_read = n;
            return result;
        }

        pub fn writeTo(self: *Self, buf: []const u8, addr: [*]const u8, addr_len: u32) PacketConn.WriteToError!usize {
            if (self.closed) return error.Unexpected;
            return posix.sendto(
                self.fd,
                buf,
                0,
                @ptrCast(addr),
                addr_len,
            ) catch |err| return switch (err) {
                error.MessageTooBig => error.MessageTooLong,
                error.NetworkUnreachable => error.NetworkUnreachable,
                error.AccessDenied => error.AccessDenied,
                else => error.Unexpected,
            };
        }

        pub fn close(self: *Self) void {
            if (!self.closed) {
                posix.close(self.fd);
                self.closed = true;
            }
        }

        pub fn deinit(self: *Self) void {
            self.close();
            if (self.allocator) |a| a.destroy(self);
        }

        pub fn packetConn(self: *Self) PacketConn {
            return PacketConn.init(self);
        }
    };
}

test "std_compat connected" {
    const std = @import("std");
    const p = std.posix;
    const UC = UdpConn(std);

    const fd_a = try p.socket(p.AF.INET, p.SOCK.DGRAM, 0);
    const fd_b = try p.socket(p.AF.INET, p.SOCK.DGRAM, 0);

    const bind_a = std.net.Ip4Address.init(.{ 127, 0, 0, 1 }, 0);
    const bind_b = std.net.Ip4Address.init(.{ 127, 0, 0, 1 }, 0);
    try p.bind(fd_a, @ptrCast(&bind_a.sa), @sizeOf(@TypeOf(bind_a.sa)));
    try p.bind(fd_b, @ptrCast(&bind_b.sa), @sizeOf(@TypeOf(bind_b.sa)));

    var addr_a: p.sockaddr.in = undefined;
    var len_a: p.socklen_t = @sizeOf(p.sockaddr.in);
    try p.getsockname(fd_a, @ptrCast(&addr_a), &len_a);

    var addr_b: p.sockaddr.in = undefined;
    var len_b: p.socklen_t = @sizeOf(p.sockaddr.in);
    try p.getsockname(fd_b, @ptrCast(&addr_b), &len_b);

    try p.connect(fd_a, @ptrCast(&addr_b), @sizeOf(p.sockaddr.in));
    try p.connect(fd_b, @ptrCast(&addr_a), @sizeOf(p.sockaddr.in));

    var uc_a = UC.init(fd_a);
    defer uc_a.close();
    var uc_b = UC.init(fd_b);
    defer uc_b.close();

    _ = try uc_a.write("connected udp");
    var buf: [64]u8 = undefined;
    const n = try uc_b.read(&buf);
    try std.testing.expectEqualStrings("connected udp", buf[0..n]);

    var ca = uc_a.conn();
    var cb = uc_b.conn();
    _ = try cb.write("via conn vtable");
    const n2 = try ca.read(&buf);
    try std.testing.expectEqualStrings("via conn vtable", buf[0..n2]);
}

test "std_compat" {
    const std = @import("std");
    const p = std.posix;
    const UC = UdpConn(std);

    const fd = try p.socket(p.AF.INET, p.SOCK.DGRAM, 0);
    const bind_addr = std.net.Ip4Address.init(.{ 127, 0, 0, 1 }, 0);
    try p.bind(fd, @ptrCast(&bind_addr.sa), @sizeOf(@TypeOf(bind_addr.sa)));

    var bound: p.sockaddr.in = undefined;
    var bound_len: p.socklen_t = @sizeOf(p.sockaddr.in);
    try p.getsockname(fd, @ptrCast(&bound), &bound_len);
    const port = std.mem.bigToNative(u16, bound.port);

    var uc = UC.init(fd);
    defer uc.close();

    const dest = std.net.Ip4Address.init(.{ 127, 0, 0, 1 }, port);
    _ = try uc.writeTo("hello udp", @ptrCast(&dest.sa), @sizeOf(@TypeOf(dest.sa)));

    var buf: [64]u8 = undefined;
    const result = try uc.readFrom(&buf);
    try std.testing.expectEqual(@as(usize, 9), result.bytes_read);
    try std.testing.expectEqualStrings("hello udp", buf[0..result.bytes_read]);

    var pc = uc.packetConn();
    _ = try pc.writeTo("via vtable", @ptrCast(&dest.sa), @sizeOf(@TypeOf(dest.sa)));

    const result2 = try pc.readFrom(&buf);
    try std.testing.expectEqualStrings("via vtable", buf[0..result2.bytes_read]);
}

test "std_compat ipv6" {
    const std = @import("std");
    const p = std.posix;
    const Addr = std.net.Address;
    const UC = UdpConn(std);

    const loopback = comptime Addr.parseIp6("::1", 0) catch unreachable;

    const fd = try p.socket(p.AF.INET6, p.SOCK.DGRAM, 0);
    try p.bind(fd, @ptrCast(&loopback.any), loopback.getOsSockLen());

    var bound: p.sockaddr.in6 = undefined;
    var bound_len: p.socklen_t = @sizeOf(p.sockaddr.in6);
    try p.getsockname(fd, @ptrCast(&bound), &bound_len);
    const port = std.mem.bigToNative(u16, bound.port);

    var uc = UC.init(fd);
    defer uc.close();

    var dest = loopback;
    dest.setPort(port);
    _ = try uc.writeTo("hello udp v6", @ptrCast(&dest.any), dest.getOsSockLen());

    var buf: [64]u8 = undefined;
    const result = try uc.readFrom(&buf);
    try std.testing.expectEqualStrings("hello udp v6", buf[0..result.bytes_read]);

    var pc = uc.packetConn();
    _ = try pc.writeTo("v6 vtable", @ptrCast(&dest.any), dest.getOsSockLen());

    const result2 = try pc.readFrom(&buf);
    try std.testing.expectEqualStrings("v6 vtable", buf[0..result2.bytes_read]);
}
