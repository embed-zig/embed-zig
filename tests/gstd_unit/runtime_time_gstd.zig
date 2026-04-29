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
}
