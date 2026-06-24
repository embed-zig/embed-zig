const grt_common = @import("grt.zig");

pub const armino = @import("bk_armino");
pub const boards = @import("boards.zig");
pub const embed = @import("embed.zig");
pub const fs = @import("grt/fs.zig");
pub const heap = @import("heap.zig");
pub const Launcher = @import("Launcher.zig");
pub const net = @import("net.zig");

pub const ap = struct {
    pub const role = @import("ap/role.zig");
    pub const grt = grt_common.make(.{
        .Thread = @import("ap/grt/std/Thread.zig"),
        .log = @import("ap/grt/std/log.zig"),
    });
};

pub const cp = struct {
    pub const role = @import("cp/role.zig");
    pub const log_impl = @import("cp/grt/std/log.zig");
    pub const grt = grt_common.make(.{
        .Thread = @import("cp/grt/std/Thread.zig"),
        .log = log_impl,
    });
};
