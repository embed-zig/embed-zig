pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/net",
    .filter = "glib/net/integration/std",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const builtin = @import("builtin");
const glib = @import("glib");
const gstd = @import("gstd");
const posix_net_impl = gstd.test_support.net;

test "glib/net/integration/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    const std_net = glib.net.make(std, gstd.runtime.time, gstd.runtime.net.Runtime);

    var t = glib.testing.T.new(std, gstd.runtime.time, .net);
    defer t.deinit();
    t.timeout(20 * glib.time.duration.Second);

    if (builtin.target.os.tag != .windows) {
        const posix_net = glib.net.make(std, gstd.runtime.time, posix_net_impl);
        t.run("glib/net/integration/std_posix", glib.net.test_runner.integration.make(std, posix_net));
    }
    t.run("glib/net/integration/std", glib.net.test_runner.integration.make(std, std_net));
    if (!t.wait()) return error.TestFailed;
}
