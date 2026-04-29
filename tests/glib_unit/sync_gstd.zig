pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/sync",
    .filter = "glib/sync/unit/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/sync/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .sync);
    defer t.deinit();

    t.run("glib/sync/unit/gstd", glib.sync.test_runner.unit.make(gstd.runtime.std, gstd.runtime.time));
    if (!t.wait()) return error.TestFailed;
}
