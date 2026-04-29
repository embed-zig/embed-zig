pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/context",
    .filter = "glib/context/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/context/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, gstd.runtime.time, .context);
    defer t.deinit();
    t.timeout(20 * glib.time.duration.Second);

    t.run("glib/context/unit/std", glib.context.test_runner.unit.make(std, gstd.runtime.time));
    if (!t.wait()) return error.TestFailed;
}
