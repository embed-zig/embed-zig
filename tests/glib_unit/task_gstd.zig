pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/task",
    .filter = "glib/task/unit/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/task/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .task);
    defer t.deinit();

    t.run("glib/task/unit/gstd", glib.task.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
