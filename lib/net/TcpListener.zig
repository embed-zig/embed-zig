//! TcpListener — binds and listens on a TCP port (like Go's net.TCPListener).
//!
//! `init()` returns a type-erased `Listener`, and callers can recover the
//! concrete implementation via `ln.as(TcpListener(lib))`.

const Conn = @import("Conn.zig");
const Listener = @import("Listener.zig");
const tcp_conn = @import("TcpConn.zig");

pub fn TcpListener(comptime lib: type) type {
    const posix = lib.posix;
    const Addr = lib.net.Address;
    const Allocator = lib.mem.Allocator;
    const SC = tcp_conn.TcpConn(lib);

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

        pub fn init(allocator: Allocator, opts: Options) !Listener {
            const fd = try posix.socket(opts.address.any.family, posix.SOCK.STREAM, 0);
            errdefer posix.close(fd);

            if (opts.reuse_addr) {
                const enable: [4]u8 = @bitCast(@as(i32, 1));
                try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enable);
            }

            try posix.bind(fd, @ptrCast(&opts.address.any), opts.address.getOsSockLen());
            try posix.listen(fd, opts.backlog);

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{ .fd = fd, .allocator = allocator };
            return Listener.init(self);
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
            errdefer posix.close(client_fd);

            return SC.init(self.allocator, client_fd) catch return error.Unexpected;
        }

        pub fn close(self: *Self) void {
            if (!self.closed) {
                posix.close(self.fd);
                self.closed = true;
            }
        }

        pub fn deinit(self: *Self) void {
            self.close();
            self.allocator.destroy(self);
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

    };
}

test "std_compat ipv4" {
    const s = @import("std");
    const Addr = s.net.Address;
    const TL = TcpListener(s);

    var ln = try TL.init(s.testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
    defer ln.deinit();

    const typed = try ln.as(TL);

    const bound_port = try typed.port();

    const cli_fd = try s.posix.socket(s.posix.AF.INET, s.posix.SOCK.STREAM, 0);
    const dest = s.net.Ip4Address.init(.{ 127, 0, 0, 1 }, bound_port);
    try s.posix.connect(cli_fd, @ptrCast(&dest.sa), @sizeOf(@TypeOf(dest.sa)));

    var cc = try tcp_conn.TcpConn(s).init(s.testing.allocator, cli_fd);
    defer cc.deinit();

    var ac = try ln.accept();
    defer ac.deinit();

    const msg = "hello Listener";
    _ = try cc.write(msg);

    var buf: [64]u8 = undefined;
    var n = try ac.read(buf[0..]);
    try s.testing.expectEqualStrings(msg, buf[0..n]);

    _ = try ac.write("back");
    n = try cc.read(buf[0..]);
    try s.testing.expectEqualStrings("back", buf[0..n]);
}

test "std_compat ipv6" {
    const s = @import("std");
    const Addr = s.net.Address;
    const TL = TcpListener(s);

    const loopback_v6 = comptime Addr.parseIp6("::1", 0) catch unreachable;

    var ln = try TL.init(s.testing.allocator, .{ .address = loopback_v6 });
    defer ln.deinit();

    const typed = try ln.as(TL);

    const bound_port = try typed.port();

    var dest = loopback_v6;
    dest.setPort(bound_port);

    const cli_fd = try s.posix.socket(s.posix.AF.INET6, s.posix.SOCK.STREAM, 0);
    try s.posix.connect(cli_fd, @ptrCast(&dest.any), dest.getOsSockLen());

    var cc = try tcp_conn.TcpConn(s).init(s.testing.allocator, cli_fd);
    defer cc.deinit();

    var ac = try ln.accept();
    defer ac.deinit();

    const msg = "hello v6 Listener";
    _ = try cc.write(msg);

    var buf: [64]u8 = undefined;
    const n = try ac.read(buf[0..]);
    try s.testing.expectEqualStrings(msg, buf[0..n]);
}
