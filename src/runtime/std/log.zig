const std = @import("std");

pub const Log = struct {
    pub fn debug(_: Log, msg: []const u8) void {
        std.debug.print("[debug] {s}\n", .{msg});
    }

    pub fn info(_: Log, msg: []const u8) void {
        std.debug.print("[info] {s}\n", .{msg});
    }

    pub fn warn(_: Log, msg: []const u8) void {
        std.debug.print("[warn] {s}\n", .{msg});
    }

    pub fn err(_: Log, msg: []const u8) void {
        std.debug.print("[error] {s}\n", .{msg});
    }
};
