const std = @import("std");
const embed_std = @import("embed_std");
const testing = @import("testing");
const bt = @import("bt");
const sync = @import("sync");
const io = @import("io");
const at = @import("at");
const ledstrip = @import("ledstrip");
const drivers = @import("drivers");
const mime = @import("mime");
const motion = @import("motion");
const net = @import("net");
const audio = @import("audio");
const zux = @import("zux");

pub const test_runner = struct {
    pub const stdz = @import("tests/stdz.zig");
    pub const context = @import("tests/context.zig");
    pub const testing_startup_probe = @import("tests/testing_startup_probe.zig");
};

test "testing/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .testing);
    defer t.deinit();

    t.run("testing/unit/std", testing.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "testing/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .testing);
    defer t.deinit();

    t.run("testing/unit/embed_std", testing.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "testing/unit/startup_probe/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .testing);
    defer t.deinit();

    t.run("testing/unit/startup_probe/std", test_runner.testing_startup_probe.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "testing/unit/startup_probe/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .testing);
    defer t.deinit();

    t.run("testing/unit/startup_probe/embed_std", test_runner.testing_startup_probe.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "mime/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .mime);
    defer t.deinit();

    t.run("mime/unit/std", mime.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "mime/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .mime);
    defer t.deinit();

    t.run("mime/unit/embed_std", mime.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

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

test "sync/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .sync);
    defer t.deinit();

    t.run("sync/unit/std", sync.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "sync/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .sync);
    defer t.deinit();

    t.run("sync/unit/embed_std", sync.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "io/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .io);
    defer t.deinit();

    t.run("io/unit/std", io.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "io/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .io);
    defer t.deinit();

    t.run("io/unit/embed_std", io.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "net/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .net);
    defer t.deinit();

    t.run("net/unit/std", net.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "net/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .net);
    defer t.deinit();

    t.run("net/unit/embed_std", net.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "net/integration/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .net);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("net/integration/std", net.test_runner.integration.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "net/integration/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .net);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("net/integration/embed_std", net.test_runner.integration.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "at/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .at);
    defer t.deinit();

    t.run("at/unit/std", at.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "at/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .at);
    defer t.deinit();

    t.run("at/unit/embed_std", at.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "at/integration/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .at);
    defer t.deinit();
    t.timeout(30 * std.time.ns_per_s);

    t.run("at/integration/std", at.test_runner.integration.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "at/integration/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .at);
    defer t.deinit();
    t.timeout(30 * embed_std.std.time.ns_per_s);

    t.run("at/integration/embed_std", at.test_runner.integration.make(embed_std.std));
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

test "sync/integration/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .sync);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("sync/integration/std", sync.test_runner.integration.make(std, embed_std.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "sync/integration/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .sync);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("sync/integration/embed_std", sync.test_runner.integration.make(embed_std.std, embed_std.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "stdz/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .stdz);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("stdz/unit/std", test_runner.stdz.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "stdz/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .stdz);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("stdz/unit/embed_std", test_runner.stdz.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "context/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .context);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("context/unit/std", test_runner.context.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "context/unit/embed_std" {
    std.testing.log_level = .info;

    var t = testing.T.new(embed_std.std, .context);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("context/unit/embed_std", test_runner.context.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}
