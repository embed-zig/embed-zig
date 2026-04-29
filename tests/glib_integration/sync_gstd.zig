pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/sync",
    .filter = "glib/sync/integration/gstd",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/sync/integration/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .sync);
    defer t.deinit();
    t.timeout(20 * glib.time.duration.Second);

    t.run("glib/sync/integration/gstd", glib.sync.test_runner.integration.make(gstd.runtime.std, gstd.runtime.time, gstd.runtime.sync.ChannelFactory));
    if (!t.wait()) return error.TestFailed;
}
