const glib = @import("glib");

const channel_mod = @import("sync/Channel.zig");

pub const impl = struct {
    pub const Mutex = @import("sync/Mutex.zig");
    pub const Condition = @import("sync/Condition.zig");
    pub const RwLock = @import("sync/RwLock.zig");
};

pub const Mutex = glib.sync.Mutex.make(impl.Mutex);
pub const Condition = glib.sync.Condition.make(impl.Condition);
pub const RwLock = glib.sync.RwLock.make(impl.RwLock);

pub const ChannelFactory = channel_mod.ChannelFactory;
