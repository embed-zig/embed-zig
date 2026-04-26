const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");
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

test "motion/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .motion);
    defer t.deinit();

    t.run("motion/unit/gstd", motion.test_runner.unit.make(gstd.runtime.std));
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

test "audio/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .audio);
    defer t.deinit();

    t.run("audio/unit/gstd", audio.test_runner.unit.make(gstd.runtime.std));
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

test "audio/integration/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .audio);
    defer t.deinit();
    t.timeout(20 * gstd.runtime.std.time.ns_per_s);

    t.run("audio/integration/gstd", audio.test_runner.integration.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}

test "zux/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .zux);
    defer t.deinit();

    t.run("zux/unit/std", zux.test_runner.unit.make(std, gstd.runtime.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "zux/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .zux);
    defer t.deinit();

    t.run("zux/unit/gstd", zux.test_runner.unit.make(gstd.runtime.std, gstd.runtime.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "zux/integration/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .zux);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("zux/integration/std", zux.test_runner.integration.make(std, gstd.runtime.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "zux/integration/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .zux);
    defer t.deinit();
    t.timeout(20 * gstd.runtime.std.time.ns_per_s);

    t.run("zux/integration/gstd", zux.test_runner.integration.make(gstd.runtime.std, gstd.runtime.sync.Channel));
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

test "bt/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .bt);
    defer t.deinit();

    t.run("bt/unit/gstd", bt.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}

test "bt/integration/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .bt);
    defer t.deinit();
    t.timeout(60 * std.time.ns_per_s);

    t.run("bt/integration/std", bt.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "bt/integration/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .bt);
    defer t.deinit();
    t.timeout(60 * gstd.runtime.std.time.ns_per_s);

    t.run("bt/integration/gstd", bt.test_runner.integration.make(gstd.runtime));
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

test "drivers/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .drivers);
    defer t.deinit();

    t.run("drivers/unit/gstd", drivers.test_runner.unit.make(gstd.runtime.std));
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

test "ledstrip/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .ledstrip);
    defer t.deinit();

    t.run("ledstrip/unit/gstd", ledstrip.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
