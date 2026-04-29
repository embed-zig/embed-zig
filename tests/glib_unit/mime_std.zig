pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/mime",
    .filter = "glib/mime/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/mime/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, gstd.runtime.time, .mime);
    defer t.deinit();

    t.run("glib/mime/unit/std", glib.mime.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}
