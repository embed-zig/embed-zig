pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/fs",
    .filter = "glib/fs/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/fs/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    const std_fs = glib.fs.make(std, gstd.test_support.fs);

    var t = glib.testing.T.new(std, gstd.runtime.time, .fs);
    defer t.deinit();

    t.run("glib/fs/unit/std", glib.fs.test_runner.unit.make(std, std_fs));
    if (!t.wait()) return error.TestFailed;
}
