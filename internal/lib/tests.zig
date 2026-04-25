const std = @import("std");
const embed_std = @import("embed_std");
const testing = @import("testing");
const bt = @import("bt");
const ledstrip = @import("ledstrip");
const drivers = @import("drivers");
const motion = @import("motion");
const net = @import("net");
const audio = @import("audio");
const zux = @import("zux");

const std_net = embed_std.posix_net;

test "motion/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .motion);
    defer t.deinit();

    t.run("motion/unit/std", motion.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "motion/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .motion);
    defer t.deinit();

    t.run("motion/unit/embed_std", motion.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "audio/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .audio);
    defer t.deinit();

    t.run("audio/unit/std", audio.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "audio/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .audio);
    defer t.deinit();

    t.run("audio/unit/embed_std", audio.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "audio/integration/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .audio);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("audio/integration/std", audio.test_runner.integration.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "audio/integration/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .audio);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("audio/integration/embed_std", audio.test_runner.integration.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "zux/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .zux);
    defer t.deinit();

    t.run("zux/unit/std", zux.test_runner.unit.make(std, embed_std.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "zux/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .zux);
    defer t.deinit();

    t.run("zux/unit/embed_std", zux.test_runner.unit.make(embed_std.std, embed_std.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "zux/integration/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .zux);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("zux/integration/std", zux.test_runner.integration.make(std, embed_std.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "zux/integration/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .zux);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("zux/integration/embed_std", zux.test_runner.integration.make(embed_std.std, embed_std.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "bt/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .bt);
    defer t.deinit();

    t.run("bt/unit/std", bt.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "bt/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .bt);
    defer t.deinit();

    t.run("bt/unit/embed_std", bt.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "bt/integration/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .bt);
    defer t.deinit();
    t.timeout(60 * std.time.ns_per_s);

    t.run("bt/integration/std", bt.test_runner.integration.make(std, embed_std.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "bt/integration/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .bt);
    defer t.deinit();
    t.timeout(60 * embed_std.std.time.ns_per_s);

    t.run("bt/integration/embed_std", bt.test_runner.integration.make(embed_std.std, embed_std.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "net/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .net);
    defer t.deinit();

    t.run("net/unit/std", net.test_runner.unit.make(std, std_net));
    if (!t.wait()) return error.TestFailed;
}

test "net/integration/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .net);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("net/integration/std", net.test_runner.integration.make(std, std_net));
    if (!t.wait()) return error.TestFailed;
}

test "drivers/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .drivers);
    defer t.deinit();

    t.run("drivers/unit/std", drivers.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "drivers/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .drivers);
    defer t.deinit();

    t.run("drivers/unit/embed_std", drivers.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "ledstrip/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .ledstrip);
    defer t.deinit();

    t.run("ledstrip/unit/std", ledstrip.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "ledstrip/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .ledstrip);
    defer t.deinit();

    t.run("ledstrip/unit/embed_std", ledstrip.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

