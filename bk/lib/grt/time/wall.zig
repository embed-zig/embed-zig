const glib = @import("glib");
const time = @import("../time.zig");

const WallClockOverride = struct {
    base_wall_ns: i128,
    base_instant_ns: u64,
};

var wall_clock_override: ?WallClockOverride = null;

pub fn now() glib.Time {
    return glib.time.fromUnixNano(wallNanoTimestamp());
}

pub fn set(value: glib.Time) !void {
    return setWallClock(value);
}

pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(wallNanoTimestamp(), glib.time.duration.MilliSecond));
}

pub fn nanoTimestamp() i128 {
    return time.instantNow();
}

pub fn wallNanoTimestamp() i128 {
    if (wallClockOverrideNowNano()) |value| return value;
    return nanoTimestamp();
}

pub fn setWallClock(value: glib.Time) !void {
    wall_clock_override = .{
        .base_wall_ns = value.unixNano(),
        .base_instant_ns = time.instantNow(),
    };
}

fn wallClockOverrideNowNano() ?i128 {
    const value = wall_clock_override orelse return null;
    const now_ns = time.instantNow();
    if (now_ns >= value.base_instant_ns) {
        return value.base_wall_ns + @as(i128, now_ns - value.base_instant_ns);
    }
    return value.base_wall_ns - @as(i128, value.base_instant_ns - now_ns);
}
