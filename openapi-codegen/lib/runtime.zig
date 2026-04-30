const zig = @import("std");
const glib = @import("glib");
const runtime_net = @import("runtime_net");

pub const time = glib.time.make(struct {
    pub const instant = struct {
        pub fn now() glib.time.instant.Time {
            const ns = zig.time.nanoTimestamp();
            if (ns <= 0) return 0;
            return @intCast(@min(ns, glib.time.instant.Maximum));
        }
    };

    pub fn now() glib.Time {
        return glib.time.fromUnixNano(zig.time.nanoTimestamp());
    }
});

pub fn net(comptime std: type) type {
    return glib.net.make(std, time, runtime_net.impl);
}
