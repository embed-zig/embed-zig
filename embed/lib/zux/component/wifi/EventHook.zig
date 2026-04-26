const drivers = @import("drivers");
const wifi_event = @import("event.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const zux_event = @import("../../event.zig");
const glib = @import("glib");

const EventHook = @This();

out: ?Emitter = null,

pub fn init() EventHook {
    return .{};
}

pub fn bindOutput(self: *EventHook, out: Emitter) void {
    self.out = out;
}

pub fn clearOutput(self: *EventHook) void {
    self.out = null;
}

pub fn attach(self: *const EventHook, adapter: drivers.wifi.Wifi) void {
    adapter.setEventCallback(@ptrCast(self), emitFn);
}

pub fn detach(_: *const EventHook, adapter: drivers.wifi.Wifi) void {
    adapter.clearEventCallback();
}

pub fn emitFn(ctx: *const anyopaque, source_id: u32, adapter_event: drivers.wifi.Wifi.Event) void {
    const self: *const EventHook = @ptrCast(@alignCast(ctx));
    const out = self.out orelse return;
    const value = wifi_event.make(zux_event.Event, source_id, adapter_event) catch @panic("zux.component.wifi.EventHook received invalid wifi event");

    out.emit(.{
        .origin = .source,
        .timestamp_ns = 0,
        .body = value,
    }) catch @panic("zux.component.wifi.EventHook failed to forward event");
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn emitFnForwardsStaThroughEmitter() !void {
            const Sink = struct {
                called: bool = false,
                last_source_id: u32 = 0,
                last_ssid_len: usize = 0,

                pub fn emit(self: *@This(), message: @import("../../pipeline/Message.zig")) !void {
                    self.called = true;
                    switch (message.body) {
                        .wifi_sta_scan_result => |value| {
                            self.last_source_id = value.source_id;
                            self.last_ssid_len = value.ssid().len;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var sink = Sink{};
            var hook = EventHook.init();
            hook.bindOutput(Emitter.init(&sink));

            EventHook.emitFn(@ptrCast(&hook), 31, .{
                .sta = .{
                    .scan_result = .{
                        .ssid = "wifi-lab",
                        .bssid = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
                        .channel = 6,
                        .rssi = -47,
                        .security = .wpa2,
                    },
                },
            });

            try grt.std.testing.expect(sink.called);
            try grt.std.testing.expectEqual(@as(u32, 31), sink.last_source_id);
            try grt.std.testing.expectEqual(@as(usize, 8), sink.last_ssid_len);
        }

        fn emitFnForwardsApThroughEmitter() !void {
            const Sink = struct {
                called: bool = false,
                last_source_id: u32 = 0,
                last_ssid_len: usize = 0,

                pub fn emit(self: *@This(), message: @import("../../pipeline/Message.zig")) !void {
                    self.called = true;
                    switch (message.body) {
                        .wifi_ap_started => |value| {
                            self.last_source_id = value.source_id;
                            self.last_ssid_len = value.ssid().len;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var sink = Sink{};
            var hook = EventHook.init();
            hook.bindOutput(Emitter.init(&sink));

            EventHook.emitFn(@ptrCast(&hook), 41, .{
                .ap = .{
                    .started = .{
                        .ssid = "esp-ap",
                        .channel = 11,
                        .security = .wpa2,
                    },
                },
            });

            try grt.std.testing.expect(sink.called);
            try grt.std.testing.expectEqual(@as(u32, 41), sink.last_source_id);
            try grt.std.testing.expectEqual(@as(usize, 6), sink.last_ssid_len);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.emitFnForwardsStaThroughEmitter() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.emitFnForwardsApThroughEmitter() catch |err| {
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
