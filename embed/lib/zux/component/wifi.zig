const drivers = @import("drivers");
const zux_event = @import("../event.zig");
const glib = @import("glib");

pub const event = @import("wifi/event.zig");
pub const state = @import("wifi/state.zig");
pub const EventHook = @import("wifi/EventHook.zig");
pub const ApReducer = @import("wifi/ApReducer.zig");
pub const StaReducer = @import("wifi/StaReducer.zig");

const EventReceiver = zux_event.EventReceiver;
const root = @This();

adapter: drivers.wifi.Wifi,

pub const max_ssid_len = event.max_ssid_len;
pub const MacAddr = event.MacAddr;
pub const Addr = event.Addr;
pub const Security = event.Security;
pub const Event = event.Event;
pub const CallbackFn = event.CallbackFn;

pub fn init(adapter: drivers.wifi.Wifi) root {
    return .{
        .adapter = adapter,
    };
}

pub fn setEventReceiver(self: *root, receiver: *const EventReceiver) void {
    self.adapter.setEventCallback(@ptrCast(receiver), eventReceiverEmitUpdate);
}

pub fn clearEventReceiver(self: *root) void {
    self.adapter.clearEventCallback();
}

fn eventReceiverEmitUpdate(ctx: *const anyopaque, source_id: u32, adapter_event: Event) void {
    const receiver: *const EventReceiver = @ptrCast(@alignCast(ctx));
    const value = event.make(zux_event.Event, source_id, adapter_event) catch @panic("zux.component.wifi received invalid wifi event");
    receiver.emit(value);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn setAndEmitReportsThroughEventReceiver() !void {
            const Sink = struct {
                sta_scan_count: usize = 0,
                sta_connected_count: usize = 0,
                sta_disconnected_count: usize = 0,
                sta_got_ip_count: usize = 0,
                sta_lost_ip_count: usize = 0,
                ap_started_count: usize = 0,
                ap_stopped_count: usize = 0,
                ap_client_joined_count: usize = 0,
                ap_client_left_count: usize = 0,
                ap_lease_granted_count: usize = 0,
                ap_lease_released_count: usize = 0,
                last_source_id: u32 = 0,
                last_ssid_len: usize = 0,
                last_reason: u16 = 0,

                fn emitFn(ctx: *anyopaque, value: zux_event.Event) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    switch (value) {
                        .wifi_sta_scan_result => |report| {
                            self.sta_scan_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_ssid_len = report.ssid().len;
                        },
                        .wifi_sta_connected => |report| {
                            self.sta_connected_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_ssid_len = report.ssid().len;
                        },
                        .wifi_sta_disconnected => |report| {
                            self.sta_disconnected_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_reason = report.reason;
                        },
                        .wifi_sta_got_ip => |report| {
                            self.sta_got_ip_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .wifi_sta_lost_ip => |report| {
                            self.sta_lost_ip_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .wifi_ap_started => |report| {
                            self.ap_started_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_ssid_len = report.ssid().len;
                        },
                        .wifi_ap_stopped => |report| {
                            self.ap_stopped_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .wifi_ap_client_joined => |report| {
                            self.ap_client_joined_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .wifi_ap_client_left => |report| {
                            self.ap_client_left_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .wifi_ap_lease_granted => |report| {
                            self.ap_lease_granted_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .wifi_ap_lease_released => |report| {
                            self.ap_lease_released_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        else => {},
                    }
                }
            };

            var sink = Sink{};
            const receiver = EventReceiver.init(@ptrCast(&sink), Sink.emitFn);

            var adapter_impl = TestCaseWifi{};
            const adapter = drivers.wifi.Wifi{
                .ptr = @ptrCast(&adapter_impl),
                .vtable = &adapter_vtable,
            };
            var component = root.init(adapter);
            component.setEventReceiver(&receiver);
            try adapter_impl.emit();

            try grt.std.testing.expectEqual(@as(usize, 1), sink.sta_scan_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.sta_connected_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.sta_disconnected_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.sta_got_ip_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.sta_lost_ip_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.ap_started_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.ap_stopped_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.ap_client_joined_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.ap_client_left_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.ap_lease_granted_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.ap_lease_released_count);
            try grt.std.testing.expectEqual(@as(u32, 41), sink.last_source_id);
            try grt.std.testing.expectEqual(@as(usize, 6), sink.last_ssid_len);
            try grt.std.testing.expectEqual(@as(u16, 7), sink.last_reason);

            component.clearEventReceiver();
            try grt.std.testing.expect(adapter_impl.receiver_ctx == null);
            try grt.std.testing.expect(adapter_impl.emit_fn == null);
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

            TestCase.setAndEmitReportsThroughEventReceiver() catch |err| {
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

const DummySta = struct {
    pub fn startScan(_: *@This(), _: drivers.wifi.Sta.ScanConfig) drivers.wifi.Sta.ScanError!void {}
    pub fn stopScan(_: *@This()) void {}
    pub fn connect(_: *@This(), _: drivers.wifi.Sta.ConnectConfig) drivers.wifi.Sta.ConnectError!void {}
    pub fn disconnect(_: *@This()) void {}
    pub fn getState(_: *@This()) drivers.wifi.Sta.State {
        return .idle;
    }
    pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, drivers.wifi.Sta.Event) void) void {}
    pub fn removeEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, drivers.wifi.Sta.Event) void) void {}
    pub fn deinit(_: *@This()) void {}
};

const DummyAp = struct {
    pub fn start(_: *@This(), _: drivers.wifi.Ap.Config) drivers.wifi.Ap.StartError!void {}
    pub fn stop(_: *@This()) void {}
    pub fn disconnectClient(_: *@This(), _: drivers.wifi.Ap.MacAddr) void {}
    pub fn getState(_: *@This()) drivers.wifi.Ap.State {
        return .idle;
    }
    pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, drivers.wifi.Ap.Event) void) void {}
    pub fn removeEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, drivers.wifi.Ap.Event) void) void {}
    pub fn deinit(_: *@This()) void {}
};

const TestCaseWifi = struct {
    receiver_ctx: ?*const anyopaque = null,
    emit_fn: ?CallbackFn = null,
    sta_impl: DummySta = .{},
    ap_impl: DummyAp = .{},

    pub fn deinit(_: *@This()) void {}

    pub fn sta(self: *@This()) drivers.wifi.Sta {
        return drivers.wifi.Sta.make(&self.sta_impl);
    }

    pub fn ap(self: *@This()) drivers.wifi.Ap {
        return drivers.wifi.Ap.make(&self.ap_impl);
    }

    pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: CallbackFn) void {
        self.receiver_ctx = ctx;
        self.emit_fn = emit_fn;
    }

    pub fn clearEventCallback(self: *@This()) void {
        self.receiver_ctx = null;
        self.emit_fn = null;
    }

    pub fn emit(self: *@This()) !void {
        const receiver_ctx = self.receiver_ctx orelse return error.MissingReceiver;
        const emit_fn = self.emit_fn orelse return error.MissingHook;

        emit_fn(receiver_ctx, 31, .{
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
        emit_fn(receiver_ctx, 31, .{
            .sta = .{
                .connected = .{
                    .ssid = "wifi-lab",
                    .bssid = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
                    .channel = 6,
                    .rssi = -41,
                    .security = .wpa2,
                },
            },
        });
        emit_fn(receiver_ctx, 31, .{
            .sta = .{
                .got_ip = .{
                    .address = Addr.from4(.{ 192, 168, 4, 2 }),
                    .gateway = Addr.from4(.{ 192, 168, 4, 1 }),
                    .netmask = Addr.from4(.{ 255, 255, 255, 0 }),
                    .dns1 = Addr.from4(.{ 1, 1, 1, 1 }),
                    .dns2 = Addr.from4(.{ 8, 8, 8, 8 }),
                },
            },
        });
        emit_fn(receiver_ctx, 31, .{
            .sta = .{
                .lost_ip = {},
            },
        });
        emit_fn(receiver_ctx, 31, .{
            .sta = .{
                .disconnected = .{
                    .reason = 7,
                },
            },
        });
        emit_fn(receiver_ctx, 41, .{
            .ap = .{
                .started = .{
                    .ssid = "esp-ap",
                    .channel = 11,
                    .security = .wpa2,
                },
            },
        });
        emit_fn(receiver_ctx, 41, .{
            .ap = .{
                .client_joined = .{
                    .mac = .{ 1, 2, 3, 4, 5, 6 },
                    .ip = null,
                    .aid = 3,
                },
            },
        });
        emit_fn(receiver_ctx, 41, .{
            .ap = .{
                .lease_granted = .{
                    .client_mac = .{ 1, 2, 3, 4, 5, 6 },
                    .client_ip = Addr.from4(.{ 192, 168, 4, 10 }),
                },
            },
        });
        emit_fn(receiver_ctx, 41, .{
            .ap = .{
                .lease_released = .{
                    .client_mac = .{ 1, 2, 3, 4, 5, 6 },
                    .client_ip = Addr.from4(.{ 192, 168, 4, 10 }),
                },
            },
        });
        emit_fn(receiver_ctx, 41, .{
            .ap = .{
                .client_left = .{
                    .mac = .{ 1, 2, 3, 4, 5, 6 },
                    .ip = Addr.from4(.{ 192, 168, 4, 10 }),
                    .aid = 3,
                },
            },
        });
        emit_fn(receiver_ctx, 41, .{
            .ap = .{
                .stopped = {},
            },
        });
    }
};

const adapter_vtable = drivers.wifi.Wifi.VTable{
    .deinit = struct {
        fn call(ptr: *anyopaque) void {
            const self: *TestCaseWifi = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
    }.call,
    .sta = struct {
        fn call(ptr: *anyopaque) drivers.wifi.Sta {
            const self: *TestCaseWifi = @ptrCast(@alignCast(ptr));
            return self.sta();
        }
    }.call,
    .ap = struct {
        fn call(ptr: *anyopaque) drivers.wifi.Ap {
            const self: *TestCaseWifi = @ptrCast(@alignCast(ptr));
            return self.ap();
        }
    }.call,
    .setEventCallback = struct {
        fn call(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
            const self: *TestCaseWifi = @ptrCast(@alignCast(ptr));
            self.setEventCallback(ctx, emit_fn);
        }
    }.call,
    .clearEventCallback = struct {
        fn call(ptr: *anyopaque) void {
            const self: *TestCaseWifi = @ptrCast(@alignCast(ptr));
            self.clearEventCallback();
        }
    }.call,
};
