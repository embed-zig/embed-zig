const std = @import("std");
const glib = @import("glib");

const posix = std.posix;

pub fn now() u64 {
    const ts = posix.clock_gettime(posix.CLOCK.UPTIME_RAW) catch unreachable;
    return timespecToNs(ts);
}

fn timespecToNs(ts: posix.timespec) u64 {
    return @intCast(
        (@as(glib.time.duration.Duration, @intCast(ts.sec)) * glib.time.duration.Second) +
            @as(glib.time.duration.Duration, @intCast(ts.nsec)),
    );
}
