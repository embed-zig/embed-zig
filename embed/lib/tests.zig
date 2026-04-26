const embed = @import("embed");
const glib = @import("glib");
const glib_stdrt = @import("glib_stdrt");
const bt = embed.bt;
const ledstrip = embed.ledstrip;
const drivers = embed.drivers;
const motion = embed.motion;
const audio = embed.audio;
const zux = embed.zux;

test "motion/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .motion);
    defer t.deinit();

    t.run("motion/unit/std", motion.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "motion/unit/glib_stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .motion);
    defer t.deinit();

    t.run("motion/unit/glib_stdrt", motion.test_runner.unit.make(glib_stdrt.std));
    if (!t.wait()) return error.TestFailed;
}

test "audio/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .audio);
    defer t.deinit();

    t.run("audio/unit/std", audio.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "audio/unit/glib_stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .audio);
    defer t.deinit();

    t.run("audio/unit/glib_stdrt", audio.test_runner.unit.make(glib_stdrt.std));
    if (!t.wait()) return error.TestFailed;
}

test "audio/integration/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .audio);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("audio/integration/std", audio.test_runner.integration.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "audio/integration/glib_stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .audio);
    defer t.deinit();
    t.timeout(20 * glib_stdrt.std.time.ns_per_s);

    t.run("audio/integration/glib_stdrt", audio.test_runner.integration.make(glib_stdrt.std));
    if (!t.wait()) return error.TestFailed;
}

test "zux/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .zux);
    defer t.deinit();

    t.run("zux/unit/std", zux.test_runner.unit.make(std, glib_stdrt.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "zux/unit/glib_stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .zux);
    defer t.deinit();

    t.run("zux/unit/glib_stdrt", zux.test_runner.unit.make(glib_stdrt.std, glib_stdrt.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "zux/integration/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .zux);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("zux/integration/std", zux.test_runner.integration.make(std, glib_stdrt.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "zux/integration/glib_stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .zux);
    defer t.deinit();
    t.timeout(20 * glib_stdrt.std.time.ns_per_s);

    t.run("zux/integration/glib_stdrt", zux.test_runner.integration.make(glib_stdrt.std, glib_stdrt.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "bt/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .bt);
    defer t.deinit();

    t.run("bt/unit/std", bt.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "bt/unit/glib_stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .bt);
    defer t.deinit();

    t.run("bt/unit/glib_stdrt", bt.test_runner.unit.make(glib_stdrt.std));
    if (!t.wait()) return error.TestFailed;
}

test "bt/integration/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .bt);
    defer t.deinit();
    t.timeout(60 * std.time.ns_per_s);

    t.run("bt/integration/std", bt.test_runner.integration.make(glib_stdrt.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "bt/integration/glib_stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .bt);
    defer t.deinit();
    t.timeout(60 * glib_stdrt.std.time.ns_per_s);

    t.run("bt/integration/glib_stdrt", bt.test_runner.integration.make(glib_stdrt.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "drivers/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .drivers);
    defer t.deinit();

    t.run("drivers/unit/std", drivers.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "drivers/unit/glib_stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .drivers);
    defer t.deinit();

    t.run("drivers/unit/glib_stdrt", drivers.test_runner.unit.make(glib_stdrt.std));
    if (!t.wait()) return error.TestFailed;
}

test "ledstrip/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .ledstrip);
    defer t.deinit();

    t.run("ledstrip/unit/std", ledstrip.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "ledstrip/unit/glib_stdrt" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(glib_stdrt.std, .ledstrip);
    defer t.deinit();

    t.run("ledstrip/unit/glib_stdrt", ledstrip.test_runner.unit.make(glib_stdrt.std));
    if (!t.wait()) return error.TestFailed;
}
