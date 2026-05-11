pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/encoding",
    .filter = "glib/encoding/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/encoding/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, gstd.runtime.time, .encoding);
    defer t.deinit();

    t.run("glib/encoding/unit/std", glib.encoding.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}
