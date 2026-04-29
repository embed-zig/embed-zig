pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/testing",
    .filter = "glib/testing/unit/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/testing/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .testing);
    defer t.deinit();

    t.run("glib/testing/unit/gstd", glib.testing.test_runner.unit.make(gstd.runtime.std, gstd.runtime.time));
    if (!t.wait()) return error.TestFailed;
}
