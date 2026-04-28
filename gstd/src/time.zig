//! Host-backed time implementations.

const builtin = @import("builtin");
const std = @import("std");

const glib = @import("glib");

pub const instant = @import("time/instant.zig");

pub const impl: type = struct {
    pub const instant: type = @import("time/instant.zig").impl;

    pub fn now() glib.Time {
        return glib.time.fromUnixNano(wallNowNano());
    }
};

fn wallNowNano() i128 {
    return switch (builtin.os.tag) {
        .windows => windowsWallNowNano(),
        .wasi => wasiWallNowNano(),
        .uefi => uefiWallNowNano(),
        else => posixWallNowNano(),
    };
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
