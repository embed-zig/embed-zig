const NetConn = @import("../Conn.zig");
const net_dialer_mod = @import("../Dialer.zig");
const conn_impl = @import("Conn.zig");

pub fn Dialer(comptime lib: type) type {
    const Addr = lib.net.Address;
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

        pub fn dial(self: Self, network: Network, addr: Addr) !NetConn {
            return switch (network) {
                .tcp => blk: {
                    var conn = try self.net_dialer.dial(.tcp, addr);
                    errdefer conn.deinit();
                    break :blk TC.init(self.net_dialer.allocator, conn, self.config);
                },
                .udp => error.UnsupportedNetwork,
            };
        }
    };
}
