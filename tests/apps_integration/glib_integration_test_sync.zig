pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/glib/integration-test/sync",
    .filter = "apps/integration/glib/integration-test/sync",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("glib_integration-test-sync");

test "apps/integration/glib/integration-test/sync" {
    const glib = @import("glib");
    const gstd = @import("gstd");
    const std = @import("std");

    std.testing.log_level = .info;

    const Launcher = app.make(gstd.runtime);

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .compat_tests);
    defer t.deinit();

    t.run("sync/integration", Launcher.createTestRunner());
    if (!t.wait()) return error.TestFailed;
}
