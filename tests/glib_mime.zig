pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/mime",
    .labels = &.{"unit"},
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/mime/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .mime);
    defer t.deinit();

    t.run("glib/mime/unit/std", glib.mime.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "glib/mime/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .mime);
    defer t.deinit();

    t.run("glib/mime/unit/gstd", glib.mime.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
