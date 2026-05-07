pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/glib/unit-test/sync",
    .filter = "apps/unit/glib/unit-test/sync",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("glib_unit-test-sync");

test "apps/unit/glib/unit-test/sync" {
    const glib = @import("glib");
    const gstd = @import("gstd");
    const std = @import("std");

    std.testing.log_level = .info;

    const Launcher = app.make(gstd.runtime);

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .compat_tests);
    defer t.deinit();

    t.run("sync/unit", Launcher.createTestRunner());
    if (!t.wait()) return error.TestFailed;
}
