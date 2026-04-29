pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/io",
    .filter = "glib/io/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/io/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, gstd.runtime.time, .io);
    defer t.deinit();

    t.run("glib/io/unit/std", glib.io.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}
