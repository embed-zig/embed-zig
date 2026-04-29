pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/stdz",
    .filter = "glib/stdz/unit/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/stdz/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .stdz);
    defer t.deinit();
    t.timeout(20 * glib.time.duration.Second);

    t.run("glib/stdz/unit/gstd", glib.std.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
