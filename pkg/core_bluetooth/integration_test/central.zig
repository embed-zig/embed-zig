const std = @import("std");
const bt = @import("bt");
const cb = @import("../../core_bluetooth.zig");
const embed_std = @import("embed_std");
const testing = @import("testing");

test "core_bluetooth/integration_tests/central" {
    std.testing.log_level = .info;
    const Bt = bt.make(std, embed_std.sync.Channel);
    const Host = Bt.makeHost(cb.Host);

    var host = try Host.init(undefined, .{
        .allocator = std.testing.allocator,
    });
    defer host.deinit();

    var t = testing.T.new(std, .core_bluetooth_central);
    defer t.deinit();

    t.run("central", bt.test_runner.central.make(std, &host));
    if (!t.wait()) return error.TestFailed;
}
