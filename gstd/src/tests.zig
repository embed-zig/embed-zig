const builtin = @import("builtin");
const glib = @import("glib");
const gstd = @import("../gstd.zig");
const net_backend = @import("net.zig");

test "testing/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .testing);
    defer t.deinit();

    t.run("testing/unit/std", glib.testing.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "testing/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .testing);
    defer t.deinit();

    t.run("testing/unit/gstd", glib.testing.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}

test "mime/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .mime);
    defer t.deinit();

    t.run("mime/unit/std", glib.mime.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "mime/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .mime);
    defer t.deinit();

    t.run("mime/unit/gstd", glib.mime.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}

test "time/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .time);
    defer t.deinit();

    t.run("time/unit/std", glib.time.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "time/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .time);
    defer t.deinit();

    t.run("time/unit/gstd", glib.time.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}

test "runtime/time/gstd" {
    const std = @import("std");

    const now = gstd.runtime.time.instant.now();
    try std.testing.expect(gstd.runtime.time.instant.since(now, now) == 0);
}

test "sync/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .sync);
    defer t.deinit();

    t.run("sync/unit/std", glib.sync.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "sync/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .sync);
    defer t.deinit();

    t.run("sync/unit/gstd", glib.sync.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}

test "sync/integration/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .sync);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("sync/integration/std", glib.sync.test_runner.integration.make(std, gstd.runtime.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "sync/integration/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .sync);
    defer t.deinit();
    t.timeout(20 * gstd.runtime.std.time.ns_per_s);

    t.run("sync/integration/gstd", glib.sync.test_runner.integration.make(gstd.runtime.std, gstd.runtime.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "io/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .io);
    defer t.deinit();

    t.run("io/unit/std", glib.io.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "io/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .io);
    defer t.deinit();

    t.run("io/unit/gstd", glib.io.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}

test "net/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    const std_net = glib.net.make(std, gstd.runtime.net.Runtime);

    var t = glib.testing.T.new(std, .net);
    defer t.deinit();

    if (builtin.target.os.tag != .windows) {
        const posix_net = glib.net.make(std, net_backend.posix_impl);
        t.run("net/unit/std_posix", glib.net.test_runner.unit.make(std, posix_net));
    }
    t.run("net/unit/std", glib.net.test_runner.unit.make(std, std_net));
    if (!t.wait()) return error.TestFailed;
}

test "net/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .net);
    defer t.deinit();

    t.run("net/unit/gstd", glib.net.test_runner.unit.make(gstd.runtime.std, gstd.runtime.net));
    if (!t.wait()) return error.TestFailed;
}

test "net/integration/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    const std_net = glib.net.make(std, gstd.runtime.net.Runtime);

    var t = glib.testing.T.new(std, .net);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    if (builtin.target.os.tag != .windows) {
        const posix_net = glib.net.make(std, net_backend.posix_impl);
        t.run("net/integration/std_posix", glib.net.test_runner.integration.make(std, posix_net));
    }
    t.run("net/integration/std", glib.net.test_runner.integration.make(std, std_net));
    if (!t.wait()) return error.TestFailed;
}

test "net/integration/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .net);
    defer t.deinit();
    t.timeout(20 * gstd.runtime.std.time.ns_per_s);

    t.run("net/integration/gstd", glib.net.test_runner.integration.make(gstd.runtime.std, gstd.runtime.net));
    if (!t.wait()) return error.TestFailed;
}

test "stdz/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .stdz);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("stdz/unit/std", glib.std.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "stdz/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .stdz);
    defer t.deinit();
    t.timeout(20 * gstd.runtime.std.time.ns_per_s);

    t.run("stdz/unit/gstd", glib.std.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}

test "context/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .context);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("context/unit/std", glib.context.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "context/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .context);
    defer t.deinit();
    t.timeout(20 * gstd.runtime.std.time.ns_per_s);

    t.run("context/unit/gstd", glib.context.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
