const std = @import("std");

const posix = std.posix;
const ns_per_s = 1_000_000_000;

pub fn now() u64 {
    const ts = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch unreachable;
    return timespecToNs(ts);
}

fn timespecToNs(ts: posix.timespec) u64 {
    return (@as(u64, @intCast(ts.sec)) * ns_per_s) + @as(u32, @intCast(ts.nsec));
}
