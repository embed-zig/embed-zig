pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/time",
    .filter = "glib/time/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/time/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, gstd.runtime.time, .time);
    defer t.deinit();

    t.run("glib/time/unit/std", glib.time.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}
