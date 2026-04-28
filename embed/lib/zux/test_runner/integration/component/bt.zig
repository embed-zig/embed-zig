const glib = @import("glib");

const bt = @import("bt");
const component_bt = @import("../../../component/bt.zig");
const zux_event = @import("../../../event.zig");

const EventReceiver = zux_event.EventReceiver;

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn initAdaptsMockerHostUpdates(allocator: glib.std.mem.Allocator) !void {
            const World = bt.Mocker(grt);
            var world = World.init(allocator, .{});
            defer world.deinit();

            var scanner_host = try world.createHost(.{
                .host = .{
                    .allocator = allocator,
                    .source_id = 11,
                },
            });
            defer scanner_host.deinit();

            var advertiser_host = try world.createHost(.{
                .host = .{
                    .allocator = allocator,
                    .source_id = 22,
                },
            });
            defer advertiser_host.deinit();

            const Sink = struct {
                started_count: usize = 0,
                stopped_count: usize = 0,
                found_count: usize = 0,
                last_started_source_id: u32 = 0,
                last_stopped_source_id: u32 = 0,
                last_found_source_id: u32 = 0,

                fn emitFn(ctx: *anyopaque, value: zux_event.Event) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    switch (value) {
                        .ble_periph_advertising_started => |report| {
                            self.started_count += 1;
                            self.last_started_source_id = report.source_id;
                        },
                        .ble_periph_advertising_stopped => |report| {
                            self.stopped_count += 1;
                            self.last_stopped_source_id = report.source_id;
                        },
                        .ble_central_found => |report| {
                            self.found_count += 1;
                            self.last_found_source_id = report.source_id;
                        },
                        else => {},
                    }
                }
            };

            var sink = Sink{};
            const receiver = EventReceiver.init(@ptrCast(&sink), Sink.emitFn);

            var scanner_bt = component_bt.init(scanner_host);
            defer scanner_bt.clearEventReceiver();
            scanner_bt.setEventReceiver(&receiver);

            var advertiser_bt = component_bt.init(advertiser_host);
            defer advertiser_bt.clearEventReceiver();
            advertiser_bt.setEventReceiver(&receiver);

            const scanner = scanner_host.central();
            const advertiser = advertiser_host.peripheral();

            try scanner.start();
            defer scanner.stop();

            try advertiser.start();
            defer advertiser.stop();

            try scanner.startScanning(.{
                .active = true,
                .filter_duplicates = false,
                .timeout = glib.time.duration.Second,
            });
            defer scanner.stopScanning();

            try advertiser.startAdvertising(.{
                .device_name = "zux-bt-host",
                .service_uuids = &.{0x180D},
            });

            var attempts: usize = 0;
            const poll_interval = 10 * grt.time.duration.MilliSecond;
            while (attempts < 50 and sink.found_count == 0) : (attempts += 1) {
                grt.std.Thread.sleep(@intCast(poll_interval));
            }

            advertiser.stopAdvertising();

            try grt.std.testing.expectEqual(@as(usize, 1), sink.started_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.stopped_count);
            try grt.std.testing.expect(sink.found_count >= 1);
            try grt.std.testing.expectEqual(@as(u32, 22), sink.last_started_source_id);
            try grt.std.testing.expectEqual(@as(u32, 22), sink.last_stopped_source_id);
            try grt.std.testing.expectEqual(@as(u32, 11), sink.last_found_source_id);
        }
    };

    // Mocker world + polling loop; similar stack demand to BT xfer harness glue.
    return glib.testing.TestRunner.fromFn(grt.std, 96 * 1024, struct {
        fn run(t: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            _ = t;
            try TestCase.initAdaptsMockerHostUpdates(allocator);
        }
    }.run);
}
