//! Dialer — configurable TCP dialer (like Go's net.Dialer).
//!
//! Usage:
//!   var d = Dialer(lib).init(allocator, .{});
//!   var conn = try d.dial(lib.net.Address.initIp4(.{127,0,0,1}, 80));
//!   defer conn.deinit();

const Conn = @import("Conn.zig");
const socket_conn = @import("SocketConn.zig");

pub fn Dialer(comptime lib: type) type {
    const posix = lib.posix;
    const Addr = lib.net.Address;
    const Allocator = lib.mem.Allocator;
    const SC = socket_conn.SocketConn(lib);

    return struct {
        allocator: Allocator,
        options: Options,

        const Self = @This();

        pub const Options = struct {};

        pub fn init(allocator: Allocator, options: Options) Self {
            return .{ .allocator = allocator, .options = options };
        }

        pub fn dial(self: Self, addr: Addr) !Conn {
            const fd = try posix.socket(addr.any.family, posix.SOCK.STREAM, 0);
            errdefer posix.close(fd);

            try posix.connect(fd, @ptrCast(&addr.any), addr.getOsSockLen());

            const sc = try self.allocator.create(SC);
            sc.* = SC.init(fd);
            sc.allocator = self.allocator;
            return sc.conn();
        }
    };
}

test "std_compat" {
    const s = @import("std");
    const Addr = s.net.Address;
    const TL = @import("TcpListener.zig").TcpListener(s);
    const D = Dialer(s);

    var ln = try TL.init(s.testing.allocator, .{ .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0) });
    defer ln.close();

    const bound_port = try ln.port();

    var d = D.init(s.testing.allocator, .{});
    var cc = try d.dial(Addr.initIp4(.{ 127, 0, 0, 1 }, bound_port));
    defer cc.deinit();

    var ac = try ln.accept();
    defer ac.deinit();

    const msg = "hello Dialer";
    try cc.writeAll(msg);

    var buf: [64]u8 = undefined;
    try ac.readAll(buf[0..msg.len]);
    try s.testing.expectEqualStrings(msg, buf[0..msg.len]);
}
