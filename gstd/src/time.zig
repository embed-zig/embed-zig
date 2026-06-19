//! Host-backed time implementations.

const builtin = @import("builtin");
const std = @import("std");

const glib = @import("glib");

pub const instant = @import("time/instant.zig");

const WallClockOverride = struct {
    base_wall_ns: i128,
    base_instant_ns: u64,
};

var wall_clock_lock: std.Thread.Mutex = .{};
var wall_clock_override: ?WallClockOverride = null;

pub const impl: type = struct {
    pub const instant: type = @import("time/instant.zig").impl;
    pub const wall: type = struct {
        pub fn now() glib.Time {
            return glib.time.fromUnixNano(wallNowNano());
        }

        pub fn set(value: glib.Time) !void {
            wall_clock_lock.lock();
            defer wall_clock_lock.unlock();
            wall_clock_override = .{
                .base_wall_ns = value.unixNano(),
                .base_instant_ns = impl.instant.now(),
            };
        }
    };

    pub fn now() glib.Time {
        return wall.now();
    }
};

fn wallNowNano() i128 {
    if (wallClockOverrideNowNano()) |value| return value;
    return switch (builtin.os.tag) {
        .windows => windowsWallNowNano(),
        .wasi => wasiWallNowNano(),
        .uefi => uefiWallNowNano(),
        else => posixWallNowNano(),
    };
}

fn wallClockOverrideNowNano() ?i128 {
    wall_clock_lock.lock();
    defer wall_clock_lock.unlock();
    const value = wall_clock_override orelse return null;
    const now_ns = impl.instant.now();
    if (now_ns >= value.base_instant_ns) {
        return value.base_wall_ns + @as(i128, now_ns - value.base_instant_ns);
    }
    return value.base_wall_ns - @as(i128, value.base_instant_ns - now_ns);
}

fn posixWallNowNano() i128 {
    const ts = std.posix.clock_gettime(.REALTIME) catch |err| switch (err) {
        error.UnsupportedClock,
        error.Unexpected,
        => return 0,
    };
    return (@as(i128, ts.sec) * glib.time.duration.Second) + ts.nsec;
}

fn windowsWallNowNano() i128 {
    const windows_epoch_seconds = -11_644_473_600;
    const hundred_nanosecond_ticks_per_second = glib.time.duration.Second / 100;
    const epoch_adjustment = windows_epoch_seconds * hundred_nanosecond_ticks_per_second;
    return (@as(i128, std.os.windows.ntdll.RtlGetSystemTimePrecise()) + epoch_adjustment) * 100;
}

fn wasiWallNowNano() i128 {
    var ns: std.os.wasi.timestamp_t = undefined;
    const err = std.os.wasi.clock_time_get(.REALTIME, 1, &ns);
    std.debug.assert(err == .SUCCESS);
    return ns;
}

fn uefiWallNowNano() i128 {
    const value, _ = std.os.uefi.system_table.runtime_services.getTime() catch return 0;
    return @intCast(value.toEpoch());
}
