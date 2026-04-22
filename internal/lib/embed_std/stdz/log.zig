//! Std-backed log impl.

const std = @import("std");
const stdz_mod = @import("stdz");
const stdz_log = stdz_mod.log;

pub fn write(
    comptime level: stdz_log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scoped_log = std.log.scoped(scope);
    const log_fn = switch (level) {
        .err => scoped_log.err,
        .warn => scoped_log.warn,
        .info => scoped_log.info,
        .debug => scoped_log.debug,
    };
    log_fn(format, args);
}
