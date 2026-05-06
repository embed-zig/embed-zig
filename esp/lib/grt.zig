const glib = @import("glib");

pub const std = @import("grt/std.zig");
pub const sync = @import("grt/sync.zig");
pub const time = @import("grt/time.zig");
pub const net = @import("grt/net.zig");

const stdz_impl = struct {
    pub const heap = std.heap;
    pub const Thread = std.Thread;
    pub const log = std.log;
    pub const crypto = std.crypto;
    pub const posix = std.posix;
    pub const testing = std.testing;
    pub const atomic = std.atomic;
};

pub const runtime: glib.runtime.Options = .{
    .stdz_impl = stdz_impl,
    .time_impl = time,
    .channel_factory = sync.ChannelFactory,
    .net_impl = net.Runtime,
};
