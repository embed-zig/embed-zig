const embed_mod = @import("embed");

pub const embed = @import("embed_std/embed.zig");
pub const std = embed_mod.make(embed);
pub const sync = struct {
    const sync_mod = @import("sync");

    pub const Channel = sync_mod.Channel(@import("embed_std/sync/Channel.zig").ChannelFactory(std));

    pub fn Racer(comptime T: type) type {
        return sync_mod.Racer(std, T);
    }
};
