//! Dialer — configurable dialer for TCP/UDP (like Go's net.Dialer).
//!
//! Usage:
//!   var d = Dialer(lib, net).init(allocator, .{});
//!   var conn = try d.dial(.tcp, addr);
//!   var conn = try d.dial(.udp, addr);
//!   var conn = try d.dialContext(ctx, .tcp, addr);

const Context = @import("context").Context;
const Conn = @import("Conn.zig");
const netip = @import("netip.zig");
const tcp_conn = @import("TcpConn.zig");
const udp_conn = @import("UdpConn.zig");

pub fn Dialer(comptime std: type, comptime net: type) type {
    const Addr = @import("netip/AddrPort.zig");
    const Allocator = std.mem.Allocator;
    const Runtime = net.Runtime;
    const TC = tcp_conn.TcpConn(std, net);
    const UC = udp_conn.UdpConn(std, net);
    // Context-only waits use short poll slices so concurrent context updates stay visible.
    const poll_quantum: net.time.duration.Duration = 50 * net.time.duration.MilliSecond;

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
            if (!addr.addr().isValid()) return error.InvalidAddress;
            return switch (network) {
                .tcp => blk: {
                    var socket = try Runtime.tcp(net.addrDomain(addr.addr()));
                    errdefer teardownTcpSocket(&socket);
                    try connectTcpSocket(null, &socket, addr);
                    break :blk try TC.initFromSocket(self.allocator, socket);
                },
                .udp => blk: {
                    var socket = try Runtime.udp(net.addrDomain(addr.addr()));
                    errdefer teardownUdpSocket(&socket);
                    try connectUdpSocket(null, &socket, addr);
                    break :blk try UC.initFromSocket(self.allocator, socket);
                },
            };
        }

        pub fn dialContext(self: Self, ctx: Context, network: Network, addr: Addr) !Conn {
            try ensureContextActive(ctx);
            if (!addr.addr().isValid()) return error.InvalidAddress;
            return switch (network) {
                .tcp => blk: {
                    var socket = try Runtime.tcp(net.addrDomain(addr.addr()));
                    errdefer teardownTcpSocket(&socket);
                    try connectTcpSocket(ctx, &socket, addr);
                    break :blk try TC.initFromSocket(self.allocator, socket);
                },
                .udp => blk: {
                    var socket = try Runtime.udp(net.addrDomain(addr.addr()));
                    errdefer teardownUdpSocket(&socket);
                    try connectUdpSocket(ctx, &socket, addr);
                    break :blk try UC.initFromSocket(self.allocator, socket);
                },
            };
        }

        fn connectTcpSocket(ctx: ?Context, socket: *Runtime.Tcp, addr: Addr) anyerror!void {
            socket.connect(addr) catch |err| switch (err) {
                error.ConnectionPending, error.WouldBlock => {},
                else => return err,
            };

            while (true) {
                try ensureOptionalContextActive(ctx);
                _ = socket.poll(.{
                    .write = true,
                    .failed = true,
                    .hup = true,
                    .write_interrupt = ctx != null,
                }, pollTimeout(ctx)) catch |err| switch (err) {
                    error.TimedOut => {
                        try ensureOptionalContextActive(ctx);
                        continue;
                    },
                    else => return err,
                };
                try ensureOptionalContextActive(ctx);
                return socket.finishConnect();
            }
        }

        fn connectUdpSocket(ctx: ?Context, socket: *Runtime.Udp, addr: Addr) anyerror!void {
            socket.connect(addr) catch |err| switch (err) {
                error.ConnectionPending, error.WouldBlock => {},
                else => return err,
            };

            while (true) {
                try ensureOptionalContextActive(ctx);
                _ = socket.poll(.{
                    .write = true,
                    .failed = true,
                    .hup = true,
                    .write_interrupt = ctx != null,
                }, pollTimeout(ctx)) catch |err| switch (err) {
                    error.TimedOut => {
                        try ensureOptionalContextActive(ctx);
                        continue;
                    },
                    else => return err,
                };
                try ensureOptionalContextActive(ctx);
                return socket.finishConnect();
            }
        }

        fn ensureContextActive(ctx: Context) anyerror!void {
            if (ctx.err()) |err| return err;
            if (ctx.deadline()) |deadline| {
                if (net.time.instant.sub(deadline, net.time.instant.now()) <= 0) return error.DeadlineExceeded;
            }
        }

        fn ensureOptionalContextActive(ctx: ?Context) anyerror!void {
            const active_ctx = ctx orelse return;
            try ensureContextActive(active_ctx);
        }

        fn pollTimeout(ctx: ?Context) ?net.time.duration.Duration {
            const active_ctx = ctx orelse return null;
            if (active_ctx.deadline()) |deadline| {
                const remaining = @max(net.time.instant.sub(deadline, net.time.instant.now()), 0);
                if (remaining <= 0) return 0;
                return @min(remaining, poll_quantum);
            }
            return poll_quantum;
        }

        fn teardownTcpSocket(socket: *Runtime.Tcp) void {
            socket.close();
            socket.deinit();
        }

        fn teardownUdpSocket(socket: *Runtime.Udp) void {
            socket.close();
            socket.deinit();
        }
    };
}
