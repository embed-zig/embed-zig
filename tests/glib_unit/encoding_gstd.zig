pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/encoding",
    .filter = "glib/encoding/unit/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/encoding/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .encoding);
    defer t.deinit();

    t.run("glib/encoding/unit/gstd", glib.encoding.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
