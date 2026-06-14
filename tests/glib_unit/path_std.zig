pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/path",
    .filter = "glib/path/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/path/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, gstd.runtime.time, .path);
    defer t.deinit();

    t.run("glib/path/unit/std", glib.path.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}
