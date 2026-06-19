pub const meta = .{
    .source_file = sourceFile(),
    .module = "gstd/runtime",
    .filter = "gstd/runtime/unit/time/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "gstd/runtime/unit/time/gstd" {
    const std = @import("std");

    const now = gstd.runtime.time.instant.now();
    try std.testing.expect(gstd.runtime.time.instant.sub(now, now) == 0);

    const restore = glib.time.fromUnixNano(std.time.nanoTimestamp());
    defer gstd.runtime.time.wall.set(glib.time.fromUnixNano(std.time.nanoTimestamp())) catch {};

    const target = glib.time.fromUnixMilli(1_700_000_000_000);
    try gstd.runtime.time.wall.set(target);
    const adjusted = gstd.runtime.time.now();
    const elapsed = adjusted.sub(target);
    try std.testing.expect(elapsed >= 0);
    try std.testing.expect(elapsed < glib.time.duration.Second);

    gstd.runtime.time.sleep(0);
    gstd.runtime.time.sleepNanos(0);
    gstd.runtime.time.sleepMillis(0);
    const sleep_start = gstd.runtime.time.instant.now();
    gstd.runtime.time.sleep(1 * glib.time.duration.MilliSecond);
    try std.testing.expect(gstd.runtime.time.instant.since(sleep_start) >= 0);

    try gstd.runtime.time.wall.set(restore);
}
