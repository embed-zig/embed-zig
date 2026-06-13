pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/compress",
    .filter = "glib/compress/unit/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/compress/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .compress);
    defer t.deinit();

    t.run("glib/compress/unit/gstd", glib.compress.test_runner.unit.make(gstd.runtime.std, gstd.runtime.compress));
    if (!t.wait()) return error.TestFailed;
}
