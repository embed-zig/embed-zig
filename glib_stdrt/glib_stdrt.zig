const glib = @import("glib");
const zig_std = @import("std");
const ChannelType = @import("src/sync/Channel.zig");
const net_backend = @import("src/net.zig");
const posix_net_backend = @import("src/net/posix.zig");
const stdz_backend = @import("src/stdz.zig");

pub const runtime = glib.runtime.make(.{
    .stdz_impl = stdz_backend,
    .channel_factory = ChannelType.ChannelFactory,
    .net_impl = net_backend.impl,
});

pub const std = runtime.std;
pub const sync = runtime.sync;
pub const net = runtime.net;
pub const posix_net = glib.net.make(zig_std, posix_net_backend.make(zig_std));
