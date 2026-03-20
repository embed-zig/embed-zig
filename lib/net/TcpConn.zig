//! TcpConn — Conn implementation over a TCP socket fd (like Go's net.TCPConn).
//!
//! Internal type used by Dialer and TcpListener.
//! Users interact with the type-erased Conn interface.

const Conn = @import("Conn.zig");

pub fn TcpConn(comptime lib: type) type {
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

        pub fn read(self: *Self, buf: []u8) Conn.ReadError!usize {
            if (self.closed) return error.EndOfStream;
            return posix.recv(self.fd, buf, 0) catch |err| return switch (err) {
                error.ConnectionResetByPeer => error.ConnectionReset,
                error.ConnectionRefused => error.ConnectionRefused,
                else => error.Unexpected,
            };
        }

        pub fn write(self: *Self, buf: []const u8) Conn.WriteError!usize {
            if (self.closed) return error.BrokenPipe;
            return posix.send(self.fd, buf, 0) catch |err| return switch (err) {
                error.ConnectionResetByPeer => error.ConnectionReset,
                error.BrokenPipe => error.BrokenPipe,
                else => error.Unexpected,
            };
        }

        pub fn close(self: *Self) void {
            if (!self.closed) {
                posix.shutdown(self.fd, .both) catch {};
                posix.close(self.fd);
                self.closed = true;
            }
        }

        pub fn deinit(self: *Self) void {
            self.close();
            if (self.allocator) |a| a.destroy(self);
        }

        pub fn conn(self: *Self) Conn {
            return Conn.init(self);
        }
    };
}

test "std_compat" {
    const s = @import("std");
    const p = s.posix;
    const SC = TcpConn(s);

    const srv = try p.socket(p.AF.INET, p.SOCK.STREAM, 0);
    defer p.close(srv);

    const enable: [4]u8 = @bitCast(@as(i32, 1));
    try p.setsockopt(srv, p.SOL.SOCKET, p.SO.REUSEADDR, &enable);

    const addr = s.net.Ip4Address.init(.{ 127, 0, 0, 1 }, 0);
    try p.bind(srv, @ptrCast(&addr.sa), @sizeOf(@TypeOf(addr.sa)));

    var bound: s.posix.sockaddr.in = undefined;
    var bound_len: p.socklen_t = @sizeOf(s.posix.sockaddr.in);
    try p.getsockname(srv, @ptrCast(&bound), &bound_len);
    const port = s.mem.bigToNative(u16, bound.port);

    try p.listen(srv, 1);

    const cli_fd = try p.socket(p.AF.INET, p.SOCK.STREAM, 0);
    const dest = s.net.Ip4Address.init(.{ 127, 0, 0, 1 }, port);
    try p.connect(cli_fd, @ptrCast(&dest.sa), @sizeOf(@TypeOf(dest.sa)));

    var client = SC.init(cli_fd);
    var cc = client.conn();
    defer cc.close();

    var peer_addr: s.posix.sockaddr.in = undefined;
    var peer_len: p.socklen_t = @sizeOf(s.posix.sockaddr.in);
    const acc_fd = try p.accept(srv, @ptrCast(&peer_addr), &peer_len, 0);

    var accepted = SC.init(acc_fd);
    var ac = accepted.conn();
    defer ac.close();

    const msg = "hello Conn";
    try cc.writeAll(msg);

    var buf: [64]u8 = undefined;
    try ac.readAll(buf[0..msg.len]);
    try s.testing.expectEqualStrings(msg, buf[0..msg.len]);

    try ac.writeAll("echo");
    try cc.readAll(buf[0..4]);
    try s.testing.expectEqualStrings("echo", buf[0..4]);
}

test "std_compat ipv6" {
    const s = @import("std");
    const p = s.posix;
    const Addr = s.net.Address;
    const TC = TcpConn(s);

    const loopback = comptime Addr.parseIp6("::1", 0) catch unreachable;

    const srv = try p.socket(p.AF.INET6, p.SOCK.STREAM, 0);
    defer p.close(srv);

    const enable: [4]u8 = @bitCast(@as(i32, 1));
    try p.setsockopt(srv, p.SOL.SOCKET, p.SO.REUSEADDR, &enable);

    try p.bind(srv, @ptrCast(&loopback.any), loopback.getOsSockLen());
    try p.listen(srv, 1);

    var bound: p.sockaddr.in6 = undefined;
    var bound_len: p.socklen_t = @sizeOf(p.sockaddr.in6);
    try p.getsockname(srv, @ptrCast(&bound), &bound_len);
    const port = s.mem.bigToNative(u16, bound.port);

    var dest = loopback;
    dest.setPort(port);

    const cli_fd = try p.socket(p.AF.INET6, p.SOCK.STREAM, 0);
    try p.connect(cli_fd, @ptrCast(&dest.any), dest.getOsSockLen());

    var client = TC.init(cli_fd);
    var cc = client.conn();
    defer cc.close();

    var peer_addr: p.sockaddr.storage = undefined;
    var peer_len: p.socklen_t = @sizeOf(p.sockaddr.storage);
    const acc_fd = try p.accept(srv, @ptrCast(&peer_addr), &peer_len, 0);

    var accepted = TC.init(acc_fd);
    var ac = accepted.conn();
    defer ac.close();

    const msg = "hello TcpConn v6";
    try cc.writeAll(msg);

    var buf: [64]u8 = undefined;
    try ac.readAll(buf[0..msg.len]);
    try s.testing.expectEqualStrings(msg, buf[0..msg.len]);

    try ac.writeAll("v6ok");
    try cc.readAll(buf[0..4]);
    try s.testing.expectEqualStrings("v6ok", buf[0..4]);
}
