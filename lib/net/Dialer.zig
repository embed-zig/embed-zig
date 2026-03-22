//! Dialer — configurable dialer for TCP/UDP (like Go's net.Dialer).
//!
//! Usage:
//!   var d = Dialer(lib).init(allocator, .{});
//!   var conn = try d.dial(.tcp, addr);
//!   var conn = try d.dial(.udp, addr);

const Conn = @import("Conn.zig");
const tcp_conn = @import("TcpConn.zig");
const udp_conn = @import("UdpConn.zig");

pub fn Dialer(comptime lib: type) type {
    const posix = lib.posix;
    const Addr = lib.net.Address;
    const Allocator = lib.mem.Allocator;
    const TC = tcp_conn.TcpConn(lib);
    const UC = udp_conn.UdpConn(lib);

    return struct {
        allocator: Allocator,
        options: Options,

        const Self = @This();

        pub const Network = enum { tcp, udp };

        pub const Options = struct {};

        pub fn init(allocator: Allocator, options: Options) Self {
            return .{ .allocator = allocator, .options = options };
        }

        pub fn dial(self: Self, network: Network, addr: Addr) !Conn {
            return switch (network) {
                .tcp => blk: {
                    const fd = try posix.socket(addr.any.family, posix.SOCK.STREAM, 0);
                    errdefer posix.close(fd);
                    try posix.connect(fd, @ptrCast(&addr.any), addr.getOsSockLen());
                    break :blk TC.init(self.allocator, fd);
                },
                .udp => blk: {
                    const fd = try posix.socket(addr.any.family, posix.SOCK.DGRAM, 0);
                    errdefer posix.close(fd);
                    try posix.connect(fd, @ptrCast(&addr.any), addr.getOsSockLen());
                    break :blk UC.init(self.allocator, fd);
                },
            };
        }
    };
}

test "std_compat" {
    const s = @import("std");
    const Addr = s.net.Address;
    const TL = @import("TcpListener.zig").TcpListener(s);
    const D = Dialer(s);

    var ln = try TL.init(s.testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
    defer ln.deinit();

    const typed = try ln.as(TL);

    const bound_port = try typed.port();

    var d = D.init(s.testing.allocator, .{});
    var cc = try d.dial(.tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, bound_port));
    defer cc.deinit();

    var ac = try ln.accept();
    defer ac.deinit();

    const msg = "hello Dialer";
    _ = try cc.write(msg);

    var buf: [64]u8 = undefined;
    const n = try ac.read(buf[0..]);
    try s.testing.expectEqualStrings(msg, buf[0..n]);
}
