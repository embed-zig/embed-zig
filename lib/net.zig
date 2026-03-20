//! net — Go-style networking for embed-zig.
//!
//! Usage:
//!   const net = @import("net").Make(lib);
//!   const Addr = lib.net.Address;
//!
//!   // Quick dial (default options):
//!   var conn = try net.dial(allocator, Addr.initIp4(.{127,0,0,1}, 80));
//!   defer conn.deinit();
//!
//!   // Configurable dialer (like Go's net.Dialer):
//!   var d = net.Dialer.init(allocator, .{});
//!   var conn = try d.dial(Addr.initIp4(.{127,0,0,1}, 80));
//!   defer conn.deinit();
//!
//!   // Listen on IPv4:
//!   var ln = try net.listen(allocator, .{ .address = Addr.initIp4(.{0,0,0,0}, 8080) });
//!
//!   // Listen on IPv6:
//!   var ln6 = try net.listen(allocator, .{ .address = Addr.initIp6(.{0}**16, 8080, 0, 0) });

pub const Conn = @import("net/Conn.zig");
pub const Listener = @import("net/Listener.zig");
pub const PacketConn = @import("net/PacketConn.zig");
pub const url = @import("net/url.zig");

const tcp_conn = @import("net/TcpConn.zig");
const tcp_listener = @import("net/TcpListener.zig");
const dialer_mod = @import("net/Dialer.zig");
const udp_conn = @import("net/UdpConn.zig");

pub fn Make(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const Addr = lib.net.Address;
    const TL = tcp_listener.TcpListener(lib);

    const UC = udp_conn.UdpConn(lib);

    return struct {
        pub const Dialer = dialer_mod.Dialer(lib);
        pub const TcpListener = TL;
        pub const UdpConn = UC;
        pub const ListenOptions = TL.Options;

        pub const ListenPacketOptions = struct {
            address: Addr = Addr.initIp4(.{ 0, 0, 0, 0 }, 0),
            reuse_addr: bool = true,
        };

        pub fn dial(allocator: Allocator, addr: Addr) !Conn {
            const d = Dialer.init(allocator, .{});
            return d.dial(addr);
        }

        pub fn listen(allocator: Allocator, opts: ListenOptions) !TL {
            return TL.init(allocator, opts);
        }

        pub fn listenPacket(opts: ListenPacketOptions) !UC {
            const posix = lib.posix;
            const fd = try posix.socket(opts.address.any.family, posix.SOCK.DGRAM, 0);
            errdefer posix.close(fd);

            if (opts.reuse_addr) {
                const enable: [4]u8 = @bitCast(@as(i32, 1));
                posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enable) catch {};
            }

            try posix.bind(fd, @ptrCast(&opts.address.any), opts.address.getOsSockLen());
            return UC.init(fd);
        }
    };
}

test {
    _ = @import("net/Conn.zig");
    _ = @import("net/Listener.zig");
    _ = @import("net/PacketConn.zig");
    _ = @import("net/TcpConn.zig");
    _ = @import("net/TcpListener.zig");
    _ = @import("net/Dialer.zig");
    _ = @import("net/UdpConn.zig");
    _ = @import("net/url.zig");
}


test "std_compat udp ipv4" {
    const std = @import("std");
    const Addr = std.net.Address;
    const Net = Make(std);

    var uc = try Net.listenPacket(.{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
    defer uc.close();

    var bound: std.posix.sockaddr.in = undefined;
    var bound_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    try std.posix.getsockname(uc.fd, @ptrCast(&bound), &bound_len);
    const port = std.mem.bigToNative(u16, bound.port);

    const dest = Addr.initIp4(.{ 127, 0, 0, 1 }, port);
    _ = try uc.writeTo("hello listenPacket", @ptrCast(&dest.any), dest.getOsSockLen());

    var buf: [64]u8 = undefined;
    const result = try uc.readFrom(&buf);
    try std.testing.expectEqualStrings("hello listenPacket", buf[0..result.bytes_read]);
}

test "std_compat udp ipv6" {
    const std = @import("std");
    const Addr = std.net.Address;
    const Net = Make(std);

    const loopback = comptime Addr.parseIp6("::1", 0) catch unreachable;

    var uc = try Net.listenPacket(.{ .address = loopback });
    defer uc.close();

    var bound: std.posix.sockaddr.in6 = undefined;
    var bound_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in6);
    try std.posix.getsockname(uc.fd, @ptrCast(&bound), &bound_len);
    const port = std.mem.bigToNative(u16, bound.port);

    var dest = loopback;
    dest.setPort(port);
    _ = try uc.writeTo("udp v6 listenPacket", @ptrCast(&dest.any), dest.getOsSockLen());

    var buf: [64]u8 = undefined;
    const r = try uc.readFrom(&buf);
    try std.testing.expectEqualStrings("udp v6 listenPacket", buf[0..r.bytes_read]);
}

test "std_compat tcp ipv4" {
    const std = @import("std");
    const Addr = std.net.Address;
    const Net = Make(std);

    var ln = try Net.listen(std.testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
    defer ln.close();

    const bound_port = try ln.port();

    var cc = try Net.dial(std.testing.allocator, Addr.initIp4(.{ 127, 0, 0, 1 }, bound_port));
    defer cc.deinit();

    var ac = try ln.accept();
    defer ac.deinit();

    const msg = "hello net.dial";
    try cc.writeAll(msg);

    var buf: [64]u8 = undefined;
    try ac.readAll(buf[0..msg.len]);
    try std.testing.expectEqualStrings(msg, buf[0..msg.len]);

    try ac.writeAll("pong");
    try cc.readAll(buf[0..4]);
    try std.testing.expectEqualStrings("pong", buf[0..4]);
}

test "std_compat tcp ipv6" {
    const std = @import("std");
    const Addr = std.net.Address;
    const Net = Make(std);

    const loopback_v6 = comptime Addr.parseIp6("::1", 0) catch unreachable;

    var ln = try Net.listen(std.testing.allocator, .{ .address = loopback_v6 });
    defer ln.close();

    const bound_port = try ln.port();

    var dial_addr = loopback_v6;
    dial_addr.setPort(bound_port);

    var cc = try Net.dial(std.testing.allocator, dial_addr);
    defer cc.deinit();

    var ac = try ln.accept();
    defer ac.deinit();

    const msg = "hello net.dial v6";
    try cc.writeAll(msg);

    var buf: [64]u8 = undefined;
    try ac.readAll(buf[0..msg.len]);
    try std.testing.expectEqualStrings(msg, buf[0..msg.len]);

    try ac.writeAll("v6ok");
    try cc.readAll(buf[0..4]);
    try std.testing.expectEqualStrings("v6ok", buf[0..4]);
}
