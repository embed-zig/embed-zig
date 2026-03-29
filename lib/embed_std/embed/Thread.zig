//! Std-backed Thread impl.

const std = @import("std");
const embed_mod = @import("embed");
const embed_thread = embed_mod.Thread;

handle: std.Thread,

const Self = @This();

pub const default_stack_size = std.Thread.SpawnConfig.default_stack_size;

pub const Id = std.Thread.Id;
pub const max_name_len = std.Thread.max_name_len;

pub const Mutex = @import("Thread/Mutex.zig");
pub const Condition = @import("Thread/Condition.zig");
pub const RwLock = @import("Thread/RwLock.zig");

pub fn spawn(config: embed_thread.SpawnConfig, comptime f: anytype, args: anytype) embed_thread.SpawnError!Self {
    const handle = try std.Thread.spawn(.{
        .stack_size = config.stack_size,
        .allocator = config.allocator,
    }, f, args);
    return .{ .handle = handle };
}

pub fn join(self: Self) void {
    self.handle.join();
}

pub fn detach(self: Self) void {
    self.handle.detach();
}

pub fn yield() embed_thread.YieldError!void {
    return try std.Thread.yield();
}

pub fn sleep(ns: u64) void {
    std.Thread.sleep(ns);
}

pub fn getCpuCount() embed_thread.CpuCountError!usize {
    return try std.Thread.getCpuCount();
}

pub fn getCurrentId() Id {
    return std.Thread.getCurrentId();
}

pub fn setName(_: []const u8) embed_thread.SetNameError!void {
    return error.Unsupported;
}

pub fn getName(_: *[max_name_len:0]u8) embed_thread.GetNameError!?[]const u8 {
    return error.Unsupported;
}
