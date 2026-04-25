const std = @import("std");
const glib = @import("glib");
const glib_stdrt = @import("../glib_stdrt.zig");

test "testing/unit/std" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .testing);
    defer t.deinit();

    t.run("testing/unit/std", glib.testing.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "testing/unit/stdrt" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .testing);
    defer t.deinit();

    t.run("testing/unit/stdrt", glib.testing.test_runner.unit.make(glib_stdrt.std));
    if (!t.wait()) return error.TestFailed;
}

test "mime/unit/std" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .mime);
    defer t.deinit();

    t.run("mime/unit/std", glib.mime.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "mime/unit/stdrt" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .mime);
    defer t.deinit();

    t.run("mime/unit/stdrt", glib.mime.test_runner.unit.make(glib_stdrt.std));
    if (!t.wait()) return error.TestFailed;
}

test "sync/unit/std" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .sync);
    defer t.deinit();

    t.run("sync/unit/std", glib.sync.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "sync/unit/stdrt" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .sync);
    defer t.deinit();

    t.run("sync/unit/stdrt", glib.sync.test_runner.unit.make(glib_stdrt.std));
    if (!t.wait()) return error.TestFailed;
}

test "sync/integration/std" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .sync);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("sync/integration/std", glib.sync.test_runner.integration.make(std, glib_stdrt.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "sync/integration/stdrt" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .sync);
    defer t.deinit();
    t.timeout(20 * glib_stdrt.std.time.ns_per_s);

    t.run("sync/integration/stdrt", glib.sync.test_runner.integration.make(glib_stdrt.std, glib_stdrt.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "io/unit/std" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .io);
    defer t.deinit();

    t.run("io/unit/std", glib.io.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "io/unit/stdrt" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .io);
    defer t.deinit();

    t.run("io/unit/stdrt", glib.io.test_runner.unit.make(glib_stdrt.std));
    if (!t.wait()) return error.TestFailed;
}

test "net/unit/std_posix" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .net);
    defer t.deinit();

    t.run("net/unit/std_posix", glib.net.test_runner.unit.make(std, glib_stdrt.posix_net));
    if (!t.wait()) return error.TestFailed;
}

test "net/unit/stdrt" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .net);
    defer t.deinit();

    t.run("net/unit/stdrt", glib.net.test_runner.unit.make(glib_stdrt.std, glib_stdrt.net));
    if (!t.wait()) return error.TestFailed;
}

test "net/integration/std_posix" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .net);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("net/integration/std_posix", glib.net.test_runner.integration.make(std, glib_stdrt.posix_net));
    if (!t.wait()) return error.TestFailed;
}

test "net/integration/stdrt" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .net);
    defer t.deinit();
    t.timeout(20 * glib_stdrt.std.time.ns_per_s);

    t.run("net/integration/stdrt", glib.net.test_runner.integration.make(glib_stdrt.std, glib_stdrt.net));
    if (!t.wait()) return error.TestFailed;
}

test "stdz/unit/std" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .stdz);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("stdz/unit/std", glib.std.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "stdz/unit/stdrt" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .stdz);
    defer t.deinit();
    t.timeout(20 * glib_stdrt.std.time.ns_per_s);

    t.run("stdz/unit/stdrt", glib.std.test_runner.unit.make(glib_stdrt.std));
    if (!t.wait()) return error.TestFailed;
}

test "context/unit/std" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .context);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("context/unit/std", glib.context.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "context/unit/stdrt" {
    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .context);
    defer t.deinit();
    t.timeout(20 * glib_stdrt.std.time.ns_per_s);

    t.run("context/unit/stdrt", glib.context.test_runner.unit.make(glib_stdrt.std));
    if (!t.wait()) return error.TestFailed;
}
