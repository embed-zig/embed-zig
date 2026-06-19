const esp = @import("esp");

pub const Time = @TypeOf(esp.grt.time.wall.now());

pub fn now() Time {
    return esp.grt.time.wall.now();
}

pub fn setWallClock(value: Time) !void {
    return esp.grt.time.wall.set(value);
}

pub fn setUnixMilli(timestamp: i64) !void {
    return setWallClock(.{
        .sec = @divFloor(timestamp, 1000),
        .nsec = @intCast(@mod(timestamp, 1000) * 1_000_000),
    });
}
