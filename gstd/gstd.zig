const glib = @import("glib");
const ChannelType = @import("src/sync/Channel.zig");
const net_backend = @import("src/net.zig");
const stdz_backend = @import("src/stdz.zig");

pub const runtime = glib.runtime.make(.{
    .stdz_impl = stdz_backend,
    .channel_factory = ChannelType.ChannelFactory,
    .net_impl = net_backend.impl,
});
