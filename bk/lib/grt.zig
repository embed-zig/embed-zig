const glib = @import("glib");

const std_common = @import("grt/std.zig");
pub const fs = @import("grt/fs.zig");

pub const sync = @import("grt/sync.zig");
pub const task = @import("grt/task.zig");
pub const time = @import("grt/time.zig");
pub const system = @import("grt/system.zig");
pub const net = @import("grt/net.zig");

pub const Options = struct {
    Thread: type,
    log: type,
};

pub fn runtime(comptime options: Options) glib.runtime.Options {
    const stdz_impl = struct {
        pub const heap = std_common.heap;
        pub const Thread = options.Thread;
        pub const log = options.log;
        pub const crypto = std_common.crypto;
        pub const posix = std_common.posix;
        pub const testing = std_common.testing;
        pub const atomic = std_common.atomic;
    };

    return .{
        .stdz_impl = stdz_impl,
        .time_impl = time,
        .system_impl = system,
        .sync_impl = sync.impl,
        .channel_factory = sync.ChannelFactory,
        .net_impl = net.Runtime,
        .fs_impl = fs.impl,
        .task_impl = task.Impl(options.Thread),
    };
}

pub fn make(comptime options: Options) type {
    return glib.runtime.make(runtime(options));
}
