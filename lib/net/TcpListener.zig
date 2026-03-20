//! TcpListener — binds and listens on a TCP port (like Go's net.TCPListener).
//!
//! Internal type used by net.listen. Users interact with the
//! type-erased Listener interface.

const Conn = @import("Conn.zig");
const Listener = @import("Listener.zig");
const socket_conn = @import("SocketConn.zig");

pub fn TcpListener(comptime lib: type) type {
    const posix = lib.posix;
    const Addr = lib.net.Address;
    const Allocator = lib.mem.Allocator;
    const SC = socket_conn.SocketConn(lib);

    return struct {
        fd: posix.socket_t,
        allocator: Allocator,
        closed: bool = false,

        const Self = @This();

        pub const Options = struct {
            address: Addr = Addr.initIp4(.{ 0, 0, 0, 0 }, 0),
            backlog: u31 = 128,
            reuse_addr: bool = true,
        };

        pub fn init(allocator: Allocator, opts: Options) !Self {
            const fd = try posix.socket(opts.address.any.family, posix.SOCK.STREAM, 0);
            errdefer posix.close(fd);

            if (opts.reuse_addr) {
                const enable: [4]u8 = @bitCast(@as(i32, 1));
                try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enable);
            }

            try posix.bind(fd, @ptrCast(&opts.address.any), opts.address.getOsSockLen());
            try posix.listen(fd, opts.backlog);

            return .{ .fd = fd, .allocator = allocator };
        }

        pub fn accept(self: *Self) Listener.AcceptError!Conn {
            if (self.closed) return error.SocketNotListening;

            var client_addr: posix.sockaddr.storage = undefined;
            var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            const client_fd = posix.accept(self.fd, @ptrCast(&client_addr), &client_len, 0) catch |err| return switch (err) {
                error.ConnectionAborted => error.ConnectionAborted,
                error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
                else => error.Unexpected,
            };

            const sc = self.allocator.create(SC) catch return error.Unexpected;
            sc.* = SC.init(client_fd);
            sc.allocator = self.allocator;
            return sc.conn();
        }

        pub fn close(self: *Self) void {
            if (!self.closed) {
                posix.close(self.fd);
                self.closed = true;
            }
        }

        pub fn port(self: *Self) !u16 {
            var bound: posix.sockaddr.storage = undefined;
            var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            posix.getsockname(self.fd, @ptrCast(&bound), &bound_len) catch return error.Unexpected;
            const family = @as(*const posix.sockaddr, @ptrCast(&bound)).family;
            return switch (family) {
                posix.AF.INET => lib.mem.bigToNative(u16, @as(*const posix.sockaddr.in, @ptrCast(@alignCast(&bound))).port),
                posix.AF.INET6 => lib.mem.bigToNative(u16, @as(*const posix.sockaddr.in6, @ptrCast(@alignCast(&bound))).port),
                else => error.Unexpected,
            };
        }

        pub fn listener(self: *Self) Listener {
            return Listener.init(self);
        }
    };
}

test "std_compat ipv4" {
    const s = @import("std");
    const Addr = s.net.Address;
    const TL = TcpListener(s);

    var ln = try TL.init(s.testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
    defer ln.close();

    const bound_port = try ln.port();

    const cli_fd = try s.posix.socket(s.posix.AF.INET, s.posix.SOCK.STREAM, 0);
    const dest = s.net.Ip4Address.init(.{ 127, 0, 0, 1 }, bound_port);
    try s.posix.connect(cli_fd, @ptrCast(&dest.sa), @sizeOf(@TypeOf(dest.sa)));

    var client = socket_conn.SocketConn(s).init(cli_fd);
    var cc = client.conn();
    defer cc.close();

    var ac = try ln.accept();
    defer ac.deinit();

    const msg = "hello Listener";
    try cc.writeAll(msg);

    var buf: [64]u8 = undefined;
    try ac.readAll(buf[0..msg.len]);
    try s.testing.expectEqualStrings(msg, buf[0..msg.len]);

    try ac.writeAll("back");
    try cc.readAll(buf[0..4]);
    try s.testing.expectEqualStrings("back", buf[0..4]);
}

test "std_compat ipv6" {
    const s = @import("std");
    const Addr = s.net.Address;
    const TL = TcpListener(s);

    const loopback_v6 = comptime Addr.parseIp6("::1", 0) catch unreachable;

    var ln = try TL.init(s.testing.allocator, .{ .address = loopback_v6 });
    defer ln.close();

    const bound_port = try ln.port();

    var dest = loopback_v6;
    dest.setPort(bound_port);

    const cli_fd = try s.posix.socket(s.posix.AF.INET6, s.posix.SOCK.STREAM, 0);
    try s.posix.connect(cli_fd, @ptrCast(&dest.any), dest.getOsSockLen());

    var client = socket_conn.SocketConn(s).init(cli_fd);
    var cc = client.conn();
    defer cc.close();

    var ac = try ln.accept();
    defer ac.deinit();

    const msg = "hello v6 Listener";
    try cc.writeAll(msg);

    var buf: [64]u8 = undefined;
    try ac.readAll(buf[0..msg.len]);
    try s.testing.expectEqualStrings(msg, buf[0..msg.len]);
}
