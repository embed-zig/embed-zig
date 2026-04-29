pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/net",
    .filter = "glib/net/integration/gstd",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const builtin = @import("builtin");
const glib = @import("glib");
const gstd = @import("gstd");
const posix_net_impl = gstd.test_support.net;

test "glib/net/integration/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .net);
    defer t.deinit();
    t.timeout(20 * glib.time.duration.Second);

    t.run("glib/net/integration/gstd", glib.net.test_runner.integration.make(gstd.runtime.std, gstd.runtime.net));
    if (!t.wait()) return error.TestFailed;
}
