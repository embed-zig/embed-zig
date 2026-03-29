//! Dialer — configurable dialer for TCP/UDP (like Go's net.Dialer).
//!
//! Usage:
//!   var d = Dialer(lib).init(allocator, .{});
//!   var conn = try d.dial(.tcp, addr);
//!   var conn = try d.dial(.udp, addr);
//!   var conn = try d.dialContext(ctx, .tcp, addr);

const Context = @import("context").Context;
const Conn = @import("Conn.zig");
const netip = @import("netip.zig");
const tcp_conn = @import("TcpConn.zig");
const udp_conn = @import("UdpConn.zig");
const fd_mod = @import("fd.zig");
const sockaddr_mod = @import("fd/SockAddr.zig");

pub fn Dialer(comptime lib: type) type {
    const Addr = @import("netip/AddrPort.zig");
    const Allocator = lib.mem.Allocator;
    const SockAddr = sockaddr_mod.SockAddr(lib);
    const TC = tcp_conn.TcpConn(lib);
    const UC = udp_conn.UdpConn(lib);
    const Stream = fd_mod.Stream(lib);
    const Packet = fd_mod.Packet(lib);

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
                    var stream = try Stream.initSocket(try SockAddr.family(addr.addr()));
                    errdefer stream.deinit();
                    try stream.connect(addr);
                    break :blk try TC.initFromStream(self.allocator, stream);
                },
                .udp => blk: {
                    var packet = try Packet.initSocket(try SockAddr.family(addr.addr()));
                    errdefer packet.deinit();
                    try packet.connect(addr);
                    break :blk try UC.initFromPacket(self.allocator, packet);
                },
            };
        }

        pub fn dialContext(self: Self, ctx: Context, network: Network, addr: Addr) !Conn {
            try ensureContextActive(ctx);
            return switch (network) {
                .tcp => blk: {
                    var stream = try Stream.initSocket(try SockAddr.family(addr.addr()));
                    errdefer stream.deinit();
                    try stream.connectContext(ctx, addr);
                    try ensureContextActive(ctx);
                    break :blk try TC.initFromStream(self.allocator, stream);
                },
                .udp => blk: {
                    var packet = try Packet.initSocket(try SockAddr.family(addr.addr()));
                    errdefer packet.deinit();
                    try packet.connect(addr);
                    try ensureContextActive(ctx);
                    break :blk try UC.initFromPacket(self.allocator, packet);
                },
            };
        }

        fn ensureContextActive(ctx: Context) anyerror!void {
            if (ctx.err()) |err| return err;
            if (ctx.deadline()) |deadline_ns| {
                if (deadline_ns <= lib.time.nanoTimestamp()) return error.DeadlineExceeded;
            }
        }
    };
}
