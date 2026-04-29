pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/context",
    .filter = "glib/context/unit/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/context/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .context);
    defer t.deinit();
    t.timeout(20 * glib.time.duration.Second);

    t.run("glib/context/unit/gstd", glib.context.test_runner.unit.make(gstd.runtime.std, gstd.runtime.time));
    if (!t.wait()) return error.TestFailed;
}
