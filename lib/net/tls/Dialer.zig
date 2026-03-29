const NetConn = @import("../Conn.zig");
const Context = @import("context").Context;
const net_dialer_mod = @import("../Dialer.zig");
const netip = @import("../netip.zig");
const conn_impl = @import("Conn.zig");

pub fn Dialer(comptime lib: type) type {
    const AddrPort = netip.AddrPort;
    const NetDialer = net_dialer_mod.Dialer(lib);
    const TC = conn_impl.Conn(lib);

    return struct {
        net_dialer: NetDialer,
        config: TC.Config,

        const Self = @This();

        pub const Network = NetDialer.Network;

        pub fn init(net_dialer: NetDialer, config: TC.Config) Self {
            return .{
                .net_dialer = net_dialer,
                .config = config,
            };
        }

        pub fn dial(self: Self, network: Network, addr: AddrPort) !NetConn {
            return switch (network) {
                .tcp => blk: {
                    var conn = try self.net_dialer.dial(.tcp, addr);
                    errdefer conn.deinit();
                    break :blk TC.init(self.net_dialer.allocator, conn, self.config);
                },
                .udp => error.UnsupportedNetwork,
            };
        }

        pub fn dialContext(self: Self, ctx: Context, network: Network, addr: AddrPort) !NetConn {
            return switch (network) {
                .tcp => blk: {
                    var conn = try self.net_dialer.dialContext(ctx, .tcp, addr);
                    errdefer conn.deinit();
                    break :blk TC.init(self.net_dialer.allocator, conn, self.config);
                },
                .udp => error.UnsupportedNetwork,
            };
        }
    };
}
