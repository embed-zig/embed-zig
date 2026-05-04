const glib = @import("glib");
pub const instant_impl = @import("time/instant.zig");

pub const instant = struct {
    pub fn now() glib.time.instant.Time {
        return instant_impl.instantNow();
    }
};

pub const wall = @import("time/wall.zig");

pub fn now() glib.Time {
    return glib.time.fromUnixNano(wall.wallNanoTimestamp());
}
