const std = @import("std");
const glib = @import("glib");
const gstd = @import("gstd");
const device = @import("device.zig");
const desktop = @import("desktop.zig");
const http = @import("http.zig");

test "device/unit/std" {
    var t = glib.testing.T.new(std, gstd.runtime.time, .std);
    defer t.deinit();

    t.run("device", device.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "device/unit/gstd" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .embed);
    defer t.deinit();

    t.run("device", device.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}

test "http/unit/std" {
    var t = glib.testing.T.new(std, gstd.runtime.time, .std);
    defer t.deinit();

    t.run("http", http.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "http/unit/gstd" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .embed);
    defer t.deinit();

    t.run("http", http.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}

test "desktop/unit/std" {
    var t = glib.testing.T.new(std, gstd.runtime.time, .std);
    defer t.deinit();

    t.run("desktop", desktop.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "desktop/unit/gstd" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .embed);
    defer t.deinit();

    t.run("desktop", desktop.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
