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

const socket_conn = @import("net/SocketConn.zig");
const tcp_listener = @import("net/TcpListener.zig");
const dialer_mod = @import("net/Dialer.zig");

pub fn Make(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const Addr = lib.net.Address;
    const TL = tcp_listener.TcpListener(lib);

    return struct {
        pub const Dialer = dialer_mod.Dialer(lib);
        pub const TcpListener = TL;
        pub const ListenOptions = TL.Options;

        pub fn dial(allocator: Allocator, addr: Addr) !Conn {
            const d = Dialer.init(allocator, .{});
            return d.dial(addr);
        }

        pub fn listen(allocator: Allocator, opts: ListenOptions) !TL {
            return TL.init(allocator, opts);
        }
    };
}

test {
    _ = @import("net/Conn.zig");
    _ = @import("net/Listener.zig");
    _ = @import("net/SocketConn.zig");
    _ = @import("net/TcpListener.zig");
    _ = @import("net/Dialer.zig");
}

test "std_compat ipv4" {
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

test "std_compat ipv6" {
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
