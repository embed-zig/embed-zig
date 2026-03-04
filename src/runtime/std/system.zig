const std = @import("std");
const runtime = @import("../root.zig");

pub const System = struct {
    pub fn getCpuCount(_: System) runtime.system.Error!usize {
        return std.Thread.getCpuCount() catch runtime.system.Error.QueryFailed;
    }
};
