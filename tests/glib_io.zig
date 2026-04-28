pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/io",
    .labels = &.{"unit"},
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/io/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .io);
    defer t.deinit();

    t.run("glib/io/unit/std", glib.io.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "glib/io/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .io);
    defer t.deinit();

    t.run("glib/io/unit/gstd", glib.io.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
