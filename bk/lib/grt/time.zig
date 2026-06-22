const glib = @import("glib");
const builtin = @import("builtin");
const std = @import("std");

const ns_per_ms: u64 = @intCast(glib.time.duration.MilliSecond);

pub const instant = struct {
    pub fn now() glib.time.instant.Time {
        return instantNow();
    }
};

pub const sleep = struct {
    /// BK delay is millisecond-based. Positive nanosecond durations round up to
    /// the next millisecond and saturate at the largest BK timeout value.
    pub fn sleep(ns: u64) void {
        if (ns == 0) return;
        if (builtin.is_test) return;
        _ = rtos_delay_milliseconds(delayMillisForNanos(ns));
    }

    pub fn delayMillisForNanos(ns: u64) u32 {
        if (ns == 0) return 0;
        const ms = (ns / ns_per_ms) + @intFromBool(ns % ns_per_ms != 0);
        return @intCast(@min(ms, glib.std.math.maxInt(u32)));
    }
};

pub const wall = @import("time/wall.zig");

pub fn now() glib.Time {
    return glib.time.fromUnixNano(wall.wallNanoTimestamp());
}

pub fn set(value: glib.Time) !void {
    return wall.setWallClock(value);
}

pub fn instantNow() u64 {
    return @as(u64, uptimeMs()) * glib.time.duration.MilliSecond;
}

fn uptimeMs() u32 {
    if (builtin.is_test) {
        const ms = @max(std.time.milliTimestamp(), 0);
        return @intCast(@mod(ms, glib.std.math.maxInt(u32)));
    }
    return rtos_get_time();
}

extern fn rtos_get_time() u32;
extern fn rtos_delay_milliseconds(num_ms: u32) c_int;
