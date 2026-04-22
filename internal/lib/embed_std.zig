const stdz_mod = @import("stdz");
const sync_mod = @import("sync");
const channel_mod = @import("embed_std/sync/Channel.zig");

pub const stdz = @import("embed_std/stdz.zig");
pub const std = stdz_mod.make(stdz);
pub const sync = struct {
    pub const ChannelFactory = channel_mod.ChannelFactory;
    pub const Channel = sync_mod.Channel(std, channel_mod.ChannelFactory);

    pub fn Racer(comptime T: type) type {
        return sync_mod.Racer(std, T);
    }
};
