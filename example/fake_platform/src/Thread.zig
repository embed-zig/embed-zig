//! Example Thread impl backed by std.Thread.

const std = @import("std");

handle: std.Thread,

const Self = @This();

pub const Id = std.Thread.Id;
pub const max_name_len = std.Thread.max_name_len;

pub const Mutex = @import("Thread/Mutex.zig");
pub const Condition = @import("Thread/Condition.zig");
pub const RwLock = @import("Thread/RwLock.zig");

pub fn spawn(_: anytype, comptime f: anytype, args: anytype) !Self {
    const handle = std.Thread.spawn(.{}, f, args) catch return error.SystemResources;
    return .{ .handle = handle };
}

pub fn join(self: Self) void {
    self.handle.join();
}

pub fn detach(self: Self) void {
    self.handle.detach();
}

pub fn yield() !void {
    std.Thread.yield() catch return error.SystemCannotYield;
}

pub fn sleep(ns: u64) void {
    std.Thread.sleep(ns);
}

pub fn getCpuCount() !usize {
    return std.Thread.getCpuCount() catch return error.Unexpected;
}

pub fn getCurrentId() Id {
    return std.Thread.getCurrentId();
}

pub fn setName(_: []const u8) std.Thread.SetNameError!void {
    return error.Unsupported;
}

pub fn getName(_: *[max_name_len:0]u8) std.Thread.GetNameError!?[]const u8 {
    return error.Unsupported;
}
