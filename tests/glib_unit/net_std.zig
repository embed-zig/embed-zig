pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/net",
    .filter = "glib/net/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const builtin = @import("builtin");
const glib = @import("glib");
const gstd = @import("gstd");
const posix_net_impl = gstd.test_support.net;

test "glib/net/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    const std_net = glib.net.make(std, gstd.runtime.time, gstd.runtime.net.Runtime);

    var t = glib.testing.T.new(std, gstd.runtime.time, .net);
    defer t.deinit();

    if (builtin.target.os.tag != .windows) {
        const posix_net = glib.net.make(std, gstd.runtime.time, posix_net_impl);
        t.run("glib/net/unit/std_posix", glib.net.test_runner.unit.make(std, posix_net));
    }
    t.run("glib/net/unit/std", glib.net.test_runner.unit.make(std, std_net));
    if (!t.wait()) return error.TestFailed;
}
