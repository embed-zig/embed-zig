const glib = @import("glib");
const build_config = @import("build_config");

pub const std = @import("grt/std.zig");
pub const sync = @import("grt/sync.zig");
pub const task = @import("grt/task.zig");
const task_policy = @import("grt/task_policy.zig");
pub const time = @import("grt/time.zig");
pub const system = @import("grt/system.zig");
pub const net = @import("grt/net.zig");
pub const fs = @import("grt/fs.zig");
pub const compress = @import("grt/compress.zig");

const stdz_impl = struct {
    pub const heap = std.heap;
    pub const log = std.log;
    pub const crypto = std.crypto;
    pub const posix = std.posix;
    pub const testing = std.testing;
    pub const atomic = std.atomic;
};

pub const runtime: glib.runtime.Options = .{
    .stdz_impl = stdz_impl,
    .time_impl = time,
    .system_impl = system,
    .sync_impl = sync.impl,
    .channel_factory = sync.ChannelFactory,
    .net_impl = net.Runtime,
    .fs_impl = fs.impl,
    .task_impl = if (@hasDecl(build_config, "task_policy"))
        task_policy.Impl(build_config.task_policy)
    else
        task.impl,
    .compress_impl = compress.impl,
};
