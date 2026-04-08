const std = @import("std");
const embed_std = @import("embed_std");
const testing = @import("testing");
const bt = @import("bt");
const sync = @import("sync");
const io = @import("io");
const wifi = @import("wifi");
const modem = @import("modem");
const at = @import("at");
const display = @import("display");
const ledstrip = @import("ledstrip");
const drivers = @import("drivers");
const mime = @import("mime");
const motion = @import("motion");
const net = @import("net");
const audio = @import("audio");
const zux = @import("zux");

pub const test_runner = struct {
    pub const embed = @import("test/embed.zig");
    pub const context = @import("test/context.zig");
};

test "testing/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("testing/unit/std", testing.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "testing/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("testing/unit/embed_std", testing.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "mime/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("mime/unit/std", mime.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "mime/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("mime/unit/embed_std", mime.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "motion/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("motion/unit/std", motion.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "motion/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("motion/unit/embed_std", motion.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "audio/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("audio/unit/std", audio.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "audio/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("audio/unit/embed_std", audio.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "audio/integration/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("audio/integration/std", audio.test_runner.integration.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "audio/integration/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("audio/integration/embed_std", audio.test_runner.integration.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "zux/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("zux/unit/std", zux.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "zux/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("zux/unit/embed_std", zux.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "zux/integration/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("zux/integration/std", zux.test_runner.integration.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "zux/integration/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("zux/integration/embed_std", zux.test_runner.integration.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "bt/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("bt/unit/std", bt.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "bt/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("bt/unit/embed_std", bt.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "bt/integration/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .std);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("bt/integration/std", bt.test_runner.integration.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "bt/integration/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("bt/integration/embed_std", bt.test_runner.integration.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "sync/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("sync/unit/std", sync.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "sync/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("sync/unit/embed_std", sync.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "io/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("io/unit/std", io.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "io/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("io/unit/embed_std", io.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "wifi/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("wifi/unit/std", wifi.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "wifi/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("wifi/unit/embed_std", wifi.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "wifi/integration/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("wifi/integration/std", wifi.test_runner.integration.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "wifi/integration/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("wifi/integration/embed_std", wifi.test_runner.integration.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "net/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("net/unit/std", net.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "net/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("net/unit/embed_std", net.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "net/integration/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("net/integration/std", net.test_runner.integration.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "net/integration/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("net/integration/embed_std", net.test_runner.integration.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "modem/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("modem/unit/std", modem.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "modem/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("modem/unit/embed_std", modem.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "display/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("display/unit/std", display.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "display/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("display/unit/embed_std", display.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "drivers/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("drivers/unit/std", drivers.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "drivers/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("drivers/unit/embed_std", drivers.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "ledstrip/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("ledstrip/unit/std", ledstrip.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "ledstrip/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("ledstrip/unit/embed_std", ledstrip.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "sync/integration/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("sync/integration/std", sync.test_runner.integration.make(std, embed_std.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "sync/integration/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("sync/integration/embed_std", sync.test_runner.integration.make(embed_std.std, embed_std.sync.Channel));
    if (!t.wait()) return error.TestFailed;
}

test "embed/unit/std" {
    std.testing.log_level = .info;

    var t = testing.T.new(std, .std);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("embed/unit/std", test_runner.embed.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "embed/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("embed/unit/embed_std", test_runner.embed.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "context/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("context/unit/std", test_runner.context.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "context/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();
    t.timeout(20 * embed_std.std.time.ns_per_s);

    t.run("context/unit/embed_std", test_runner.context.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}
