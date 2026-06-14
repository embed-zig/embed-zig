pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/archive",
    .filter = "glib/archive/unit/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/archive/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .archive);
    defer t.deinit();

    t.run("glib/archive/unit/gstd", glib.archive.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
