//! Log contract — follows std.log conventions.
//!
//! Usage (after embed.Make):
//!   const log = embed.log.scoped(.my_module);
//!   log.info("hello {}", .{42});
//!
//!   embed.log.info("default scope", .{});

const root = @This();
const builtin = @import("builtin");

pub const Level = enum {
    err,
    warn,
    info,
    debug,

    pub fn asText(comptime self: Level) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warning",
            .info => "info",
            .debug => "debug",
        };
    }
};

pub const default_level: Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .info,
};

/// Construct a sealed log namespace from a platform Impl.
///
/// Impl must provide:
///   fn write(comptime Level, comptime @Type(.enum_literal), comptime []const u8, anytype) void
pub fn make(comptime Impl: type) type {
    return struct {
        pub const Level = root.Level;
        pub const default_level = root.default_level;

        pub fn scoped(comptime scope: @Type(.enum_literal)) type {
            return struct {
                pub inline fn err(comptime format: []const u8, args: anytype) void {
                    @branchHint(.cold);
                    Impl.write(.err, scope, format, args);
                }

                pub inline fn warn(comptime format: []const u8, args: anytype) void {
                    Impl.write(.warn, scope, format, args);
                }

                pub inline fn info(comptime format: []const u8, args: anytype) void {
                    Impl.write(.info, scope, format, args);
                }

                pub inline fn debug(comptime format: []const u8, args: anytype) void {
                    Impl.write(.debug, scope, format, args);
                }
            };
        }

        const default = scoped(.default);
        pub const err = default.err;
        pub const warn = default.warn;
        pub const info = default.info;
        pub const debug = default.debug;
    };
}
