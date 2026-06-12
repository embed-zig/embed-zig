pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/fs",
    .filter = "glib/fs/unit/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/fs/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .fs);
    defer t.deinit();

    t.run("glib/fs/unit/gstd", glib.fs.test_runner.unit.make(gstd.runtime.std, gstd.runtime.fs));
    if (!t.wait()) return error.TestFailed;
}
