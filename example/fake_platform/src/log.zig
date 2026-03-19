//! Example log impl backed by std.log.defaultLog.

const std = @import("std");
const embed_log = @import("embed").log;

pub fn write(
    comptime level: embed_log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const std_level: std.log.Level = switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
    std.log.defaultLog(std_level, scope, format, args);
}
