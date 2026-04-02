const std = @import("std");
const bt = @import("bt");
const cb = @import("../../core_bluetooth.zig");
const embed_std = @import("embed_std");
const testing = @import("testing");

test "core_bluetooth/integration_tests/peripheral" {
    std.testing.log_level = .info;
    const Bt = bt.make(std, embed_std.sync.Channel);
    const Host = Bt.makeHost(cb.Host);

    var host = try Host.init(undefined, .{
        .allocator = std.testing.allocator,
    });
    defer host.deinit();

    var t = testing.T.new(std, .core_bluetooth_peripheral);
    defer t.deinit();

    t.timeout(5 * std.time.ns_per_s);
    t.run("peripheral", bt.test_runner.peripheral.make(std, &host));
    if (!t.wait()) return error.TestFailed;
}

test "core_bluetooth/integration_tests/host_callback_emits_advertising_lifecycle" {
    const Bt = bt.make(std, embed_std.sync.Channel);
    const Host = Bt.makeHost(cb.Host);

    var host = try Host.init(undefined, .{
        .allocator = std.testing.allocator,
        .source_id = 91,
    });
    defer host.deinit();

    const Sink = struct {
        started_count: usize = 0,
        stopped_count: usize = 0,
        last_started_source_id: u32 = 0,
        last_stopped_source_id: u32 = 0,

        fn emitFn(ctx: *const anyopaque, source_id: u32, event: bt.Host.Event) void {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
            switch (event) {
                .peripheral => |peripheral_event| switch (peripheral_event) {
                    .advertising_started => {
                        self.started_count += 1;
                        self.last_started_source_id = source_id;
                    },
                    .advertising_stopped => {
                        self.stopped_count += 1;
                        self.last_stopped_source_id = source_id;
                    },
                    else => {},
                },
                else => {},
            }
        }
    };

    var sink = Sink{};
    host.setEventCallback(@ptrCast(&sink), Sink.emitFn);

    const peripheral = host.peripheral();
    try peripheral.startAdvertising(.{
        .device_name = "EmbedHostCb",
    });
    peripheral.stopAdvertising();

    try std.testing.expectEqual(@as(usize, 1), sink.started_count);
    try std.testing.expectEqual(@as(usize, 1), sink.stopped_count);
    try std.testing.expectEqual(@as(u32, 91), sink.last_started_source_id);
    try std.testing.expectEqual(@as(u32, 91), sink.last_stopped_source_id);

    host.clearEventCallback();

    try peripheral.startAdvertising(.{
        .device_name = "EmbedHostCbOff",
    });
    peripheral.stopAdvertising();

    try std.testing.expectEqual(@as(usize, 1), sink.started_count);
    try std.testing.expectEqual(@as(usize, 1), sink.stopped_count);
}
