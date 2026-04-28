const glib = @import("glib");
const bt = @import("embed").bt;
const cb = @import("../../../core_bluetooth.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Bt = bt.make(grt);
            const Host = Bt.makeHost(cb.Host);

            var host = Host.init(undefined, .{
                .allocator = grt.std.testing.allocator,
                .source_id = 91,
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer host.deinit();

            const Sink = struct {
                started_count: usize = 0,
                stopped_count: usize = 0,
                last_started_source_id: u32 = 0,
                last_stopped_source_id: u32 = 0,

                fn emitFn(ctx: *const anyopaque, source_id: u32, event: bt.Host.Event) void {
                    const sink: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
                    switch (event) {
                        .peripheral => |peripheral_event| switch (peripheral_event) {
                            .advertising_started => {
                                sink.started_count += 1;
                                sink.last_started_source_id = source_id;
                            },
                            .advertising_stopped => {
                                sink.stopped_count += 1;
                                sink.last_stopped_source_id = source_id;
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
            peripheral.startAdvertising(.{
                .device_name = "EmbedHostCb",
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            peripheral.stopAdvertising();

            grt.std.testing.expectEqual(@as(usize, 1), sink.started_count) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(usize, 1), sink.stopped_count) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(u32, 91), sink.last_started_source_id) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(u32, 91), sink.last_stopped_source_id) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            host.clearEventCallback();

            peripheral.startAdvertising(.{
                .device_name = "EmbedHostCbOff",
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            peripheral.stopAdvertising();

            grt.std.testing.expectEqual(@as(usize, 1), sink.started_count) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(usize, 1), sink.stopped_count) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
