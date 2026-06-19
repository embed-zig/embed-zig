pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/system",
    .filter = "glib/system/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/system/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, gstd.runtime.time, .system);
    defer t.deinit();

    t.run("glib/system/unit/std", glib.system.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}
