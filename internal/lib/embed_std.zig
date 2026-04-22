const embed_mod = @import("embed");
const sync_mod = @import("sync");
const channel_mod = @import("embed_std/sync/Channel.zig");

pub const embed = @import("embed_std/embed.zig");
pub const std = embed_mod.make(embed);
pub const sync = struct {
    pub const ChannelFactory = channel_mod.ChannelFactory;
    pub const Channel = sync_mod.Channel(std, channel_mod.ChannelFactory);

    pub fn Racer(comptime T: type) type {
        return sync_mod.Racer(std, T);
    }
};
