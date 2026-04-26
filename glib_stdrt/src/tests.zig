const glib = @import("glib");
const glib_stdrt = @import("../glib_stdrt.zig");
const net_backend = @import("net.zig");

test "testing/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .testing);
    defer t.deinit();

    t.run("testing/unit/std", glib.testing.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "testing/unit/stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.runtime.std, .testing);
    defer t.deinit();

    t.run("testing/unit/stdrt", glib.testing.test_runner.unit.make(glib_stdrt.runtime.std));
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

test "mime/unit/stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.runtime.std, .mime);
    defer t.deinit();

    t.run("mime/unit/stdrt", glib.mime.test_runner.unit.make(glib_stdrt.runtime.std));
    if (!t.wait()) return error.TestFailed;
}

test "sync/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .sync);
    defer t.deinit();

    t.run("sync/unit/std", glib.sync.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "sync/unit/stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.runtime.std, .sync);
    defer t.deinit();

    t.run("sync/unit/stdrt", glib.sync.test_runner.unit.make(glib_stdrt.runtime.std));
    if (!t.wait()) return error.TestFailed;
}

test "sync/integration/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .sync);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("sync/integration/std", glib.sync.test_runner.integration.make(std, glib_stdrt.runtime.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "sync/integration/stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.runtime.std, .sync);
    defer t.deinit();
    t.timeout(20 * glib_stdrt.runtime.std.time.ns_per_s);

    t.run("sync/integration/stdrt", glib.sync.test_runner.integration.make(glib_stdrt.runtime.std, glib_stdrt.runtime.sync.Channel));
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

test "io/unit/stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.runtime.std, .io);
    defer t.deinit();

    t.run("io/unit/stdrt", glib.io.test_runner.unit.make(glib_stdrt.runtime.std));
    if (!t.wait()) return error.TestFailed;
}

test "net/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    const posix_net = glib.net.make(std, net_backend.posix_impl);
    const std_stdrt_net = glib.net.make(std, glib_stdrt.runtime.net.Runtime);

    var t = glib.testing.T.new(std, .net);
    defer t.deinit();

    t.run("net/unit/std_posix", glib.net.test_runner.unit.make(std, posix_net));
    t.run("net/unit/std_stdrt", glib.net.test_runner.unit.make(std, std_stdrt_net));
    if (!t.wait()) return error.TestFailed;
}

test "net/unit/stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.runtime.std, .net);
    defer t.deinit();

    t.run("net/unit/stdrt", glib.net.test_runner.unit.make(glib_stdrt.runtime.std, glib_stdrt.runtime.net));
    if (!t.wait()) return error.TestFailed;
}

test "net/integration/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    const posix_net = glib.net.make(std, net_backend.posix_impl);
    const std_stdrt_net = glib.net.make(std, glib_stdrt.runtime.net.Runtime);

    var t = glib.testing.T.new(std, .net);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("net/integration/std_posix", glib.net.test_runner.integration.make(std, posix_net));
    t.run("net/integration/std_stdrt", glib.net.test_runner.integration.make(std, std_stdrt_net));
    if (!t.wait()) return error.TestFailed;
}

test "net/integration/stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.runtime.std, .net);
    defer t.deinit();
    t.timeout(20 * glib_stdrt.runtime.std.time.ns_per_s);

    t.run("net/integration/stdrt", glib.net.test_runner.integration.make(glib_stdrt.runtime.std, glib_stdrt.runtime.net));
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

test "stdz/unit/stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.runtime.std, .stdz);
    defer t.deinit();
    t.timeout(20 * glib_stdrt.runtime.std.time.ns_per_s);

    t.run("stdz/unit/stdrt", glib.std.test_runner.unit.make(glib_stdrt.runtime.std));
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

test "context/unit/stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.runtime.std, .context);
    defer t.deinit();
    t.timeout(20 * glib_stdrt.runtime.std.time.ns_per_s);

    t.run("context/unit/stdrt", glib.context.test_runner.unit.make(glib_stdrt.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
