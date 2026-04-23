const stdz_api = @import("stdz");
const sync_api = @import("sync");
const net_api = @import("net");
const ChannelType = @import("embed_std/sync/Channel.zig");
pub const net_impl = @import("embed_std/net.zig");
const stdz_impl = @import("embed_std/stdz.zig");

pub const std = stdz_api.make(stdz_impl);
pub const net = net_api.make2(std, net_impl.impl);
pub const sync = struct {
    pub const ChannelFactory = ChannelType.ChannelFactory;
    pub const Channel = sync_api.Channel(std, ChannelType.ChannelFactory);

    pub fn Racer(comptime T: type) type {
        return sync_api.Racer(std, T);
    }
};
