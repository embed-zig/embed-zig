const std = @import("std");
const bt = @import("bt");
const cb = @import("../../core_bluetooth.zig");
const testing = @import("testing");

test "core_bluetooth/integration_tests/peripheral" {
    std.testing.log_level = .info;

    var host = try cb.Host.init(undefined, .{
        .allocator = std.testing.allocator,
    });
    defer host.deinit();

    var t = testing.T.new(std, .core_bluetooth_peripheral);
    defer t.deinit();

    t.timeout(5 * std.time.ns_per_s);
    t.run("peripheral", bt.test_runner.peripheral.make(std, &host));
    if (!t.wait()) return error.TestFailed;
}
