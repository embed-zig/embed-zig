pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/glib/unit-test",
    .filter = "apps/unit/glib/unit-test",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("glib_unit-test");

test "apps/unit/glib/unit-test" {
    const glib = @import("glib");
    const gstd = @import("gstd");
    const std = @import("std");

    std.testing.log_level = .info;

    const Launcher = app.make(gstd.runtime);

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .compat_tests);
    defer t.deinit();

    t.run("std/unit", Launcher.createTestRunner());
    if (!t.wait()) return error.TestFailed;
}
