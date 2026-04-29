pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/time",
    .filter = "glib/time/unit/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/time/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .time);
    defer t.deinit();

    t.run("glib/time/unit/gstd", glib.time.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
