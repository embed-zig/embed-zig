const std = @import("std");
const dep = @import("dep");
const device = @import("device.zig");
const desktop = @import("desktop.zig");
const embed_std = dep.embed_std;
const http = @import("http.zig");
const testing = dep.testing;

test "device/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("device", device.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "device/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("device", device.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "http/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("http", http.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "http/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("http", http.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}

test "desktop/unit/std" {
    var t = testing.T.new(std, .std);
    defer t.deinit();

    t.run("desktop", desktop.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "desktop/unit/embed_std" {
    var t = testing.T.new(embed_std.std, .embed);
    defer t.deinit();

    t.run("desktop", desktop.test_runner.unit.make(embed_std.std));
    if (!t.wait()) return error.TestFailed;
}
