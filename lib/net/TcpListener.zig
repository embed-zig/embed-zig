//! TcpListener — binds a TCP port and starts listening on demand.
//!
//! `init()` binds but does not call `listen()`. Callers can invoke `listen()`
//! directly, or use `net.listen(...)` / `net.tls.listen(...)` for a one-shot
//! bind+listen convenience.

const Conn = @import("Conn.zig");
const Listener = @import("Listener.zig");
const tcp_conn = @import("TcpConn.zig");
const fd_mod = @import("fd.zig");
const sockaddr_mod = @import("fd/SockAddr.zig");

pub fn TcpListener(comptime lib: type) type {
    const AddrPort = @import("netip/AddrPort.zig");
    const Allocator = lib.mem.Allocator;
    const FdListener = fd_mod.Listener(lib);
    const SC = tcp_conn.TcpConn(lib);

    return struct {
        listener: FdListener,
        allocator: Allocator,
        backlog: u31,

        const Self = @This();

        pub const Options = struct {
            address: AddrPort = AddrPort.from4(.{ 0, 0, 0, 0 }, 0),
            backlog: u31 = 128,
            reuse_addr: bool = true,
        };

        pub fn init(allocator: Allocator, opts: Options) !Listener {
            const listener = try FdListener.init(opts.address, opts.reuse_addr);

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .listener = listener,
                .allocator = allocator,
                .backlog = opts.backlog,
            };
            return Listener.init(self);
        }

        pub fn listen(self: *Self) Listener.ListenError!void {
            self.listener.listen(self.backlog) catch |err| return switch (err) {
                error.Closed => error.SocketNotListening,
                else => err,
            };
        }

        pub fn accept(self: *Self) Listener.AcceptError!Conn {
            var stream = self.listener.accept() catch |err| return switch (err) {
                error.Closed, error.SocketNotListening => error.SocketNotListening,
                error.ConnectionAborted => error.ConnectionAborted,
                error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
                else => error.Unexpected,
            };
            errdefer stream.deinit();

            return SC.initFromStream(self.allocator, stream) catch return error.Unexpected;
        }

        pub fn close(self: *Self) void {
            self.listener.close();
        }

        pub fn deinit(self: *Self) void {
            self.listener.deinit();
            self.allocator.destroy(self);
        }

        pub fn port(self: *Self) !u16 {
            return self.listener.port() catch return error.Unexpected;
        }
    };
}

test "net/unit_tests/TcpListener/std_compat_ipv4" {
    const s = @import("std");
    const Addr = @import("netip/AddrPort.zig");
    const SockAddr = sockaddr_mod.SockAddr(s);
    const TL = TcpListener(s);

    var ln = try TL.init(s.testing.allocator, .{ .address = Addr.from4(.{ 127, 0, 0, 1 }, 0) });
    defer ln.deinit();
    try ln.listen();

    const typed = try ln.as(TL);

    const bound_port = try typed.port();

    const cli_fd = try s.posix.socket(s.posix.AF.INET, s.posix.SOCK.STREAM, 0);
    const dest = try SockAddr.encode(Addr.from4(.{ 127, 0, 0, 1 }, bound_port));
    try s.posix.connect(cli_fd, @ptrCast(&dest.storage), dest.len);

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

test "net/unit_tests/TcpListener/std_compat_ipv6" {
    const s = @import("std");
    const Addr = @import("netip/AddrPort.zig");
    const IpAddr = @import("netip/Addr.zig");
    const SockAddr = sockaddr_mod.SockAddr(s);
    const TL = TcpListener(s);

    const loopback_v6 = Addr.init(try IpAddr.parse("::1"), 0);

    var ln = try TL.init(s.testing.allocator, .{ .address = loopback_v6 });
    defer ln.deinit();
    try ln.listen();

    const typed = try ln.as(TL);

    const bound_port = try typed.port();

    const dest = try SockAddr.encode(loopback_v6.withPort(bound_port));

    const cli_fd = try s.posix.socket(s.posix.AF.INET6, s.posix.SOCK.STREAM, 0);
    try s.posix.connect(cli_fd, @ptrCast(&dest.storage), dest.len);

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
