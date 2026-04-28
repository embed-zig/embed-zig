pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/sync",
    .labels = &.{ "integration", "unit" },
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/sync/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, gstd.runtime.time, .sync);
    defer t.deinit();

    t.run("glib/sync/unit/std", glib.sync.test_runner.unit.make(std, gstd.runtime.time));
    if (!t.wait()) return error.TestFailed;
}

test "glib/sync/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .sync);
    defer t.deinit();

    t.run("glib/sync/unit/gstd", glib.sync.test_runner.unit.make(gstd.runtime.std, gstd.runtime.time));
    if (!t.wait()) return error.TestFailed;
}

test "glib/sync/integration/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, gstd.runtime.time, .sync);
    defer t.deinit();
    t.timeout(20 * glib.time.duration.Second);

    t.run("glib/sync/integration/std", glib.sync.test_runner.integration.make(std, gstd.runtime.time, gstd.runtime.sync.ChannelFactory));
    if (!t.wait()) return error.TestFailed;
}

test "glib/sync/integration/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .sync);
    defer t.deinit();
    t.timeout(20 * glib.time.duration.Second);

    t.run("glib/sync/integration/gstd", glib.sync.test_runner.integration.make(gstd.runtime.std, gstd.runtime.time, gstd.runtime.sync.ChannelFactory));
    if (!t.wait()) return error.TestFailed;
}
