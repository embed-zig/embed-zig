const std = @import("std");
const wifi = @import("wifi");
const core_wlan = @import("../../core_wlan.zig");
const testing = @import("testing");

test "core_wlan/integration_tests/sta" {
    std.testing.log_level = .info;

    var device = try core_wlan.Wifi.init(.{
        .allocator = std.testing.allocator,
    });
    defer device.deinit();

    var t = testing.T.new(std, .core_wlan_sta);
    defer t.deinit();

    t.run("sta", wifi.test_runner.sta.make(std, &device));
    if (!t.wait()) return error.TestFailed;
}
