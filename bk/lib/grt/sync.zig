const glib = @import("glib");
const channel_mod = @import("sync/Channel.zig");

pub const impl = struct {
    pub const Mutex = @import("sync/Mutex.zig").Impl;
    pub const Condition = @import("sync/Condition.zig").Impl;
    pub const RwLock = @import("sync/RwLock.zig").Impl;
};

pub const Mutex = glib.sync.Mutex.make(impl.Mutex);
pub const Condition = glib.sync.Condition.make(impl.Condition);
pub const RwLock = glib.sync.RwLock.make(impl.RwLock);

pub const Channel = channel_mod.Channel;
pub const ChannelFactory = channel_mod.ChannelFactory;
