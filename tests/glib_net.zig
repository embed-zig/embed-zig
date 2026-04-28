pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/net",
    .labels = &.{ "integration", "unit" },
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

    const std_net = glib.net.make(std, gstd.runtime.net.Runtime);

    var t = glib.testing.T.new(std, .net);
    defer t.deinit();

    if (builtin.target.os.tag != .windows) {
        const posix_net = glib.net.make(std, posix_net_impl);
        t.run("glib/net/unit/std_posix", glib.net.test_runner.unit.make(std, posix_net));
    }
    t.run("glib/net/unit/std", glib.net.test_runner.unit.make(std, std_net));
    if (!t.wait()) return error.TestFailed;
}

test "glib/net/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .net);
    defer t.deinit();

    t.run("glib/net/unit/gstd", glib.net.test_runner.unit.make(gstd.runtime.std, gstd.runtime.net));
    if (!t.wait()) return error.TestFailed;
}

test "glib/net/integration/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    const std_net = glib.net.make(std, gstd.runtime.net.Runtime);

    var t = glib.testing.T.new(std, .net);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    if (builtin.target.os.tag != .windows) {
        const posix_net = glib.net.make(std, posix_net_impl);
        t.run("glib/net/integration/std_posix", glib.net.test_runner.integration.make(std, posix_net));
    }
    t.run("glib/net/integration/std", glib.net.test_runner.integration.make(std, std_net));
    if (!t.wait()) return error.TestFailed;
}

test "glib/net/integration/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .net);
    defer t.deinit();
    t.timeout(20 * gstd.runtime.std.time.ns_per_s);

    t.run("glib/net/integration/gstd", glib.net.test_runner.integration.make(gstd.runtime.std, gstd.runtime.net));
    if (!t.wait()) return error.TestFailed;
}
