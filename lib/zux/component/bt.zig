const bt = @import("bt");
const zux_event = @import("../event.zig");
const testing_api = @import("testing");

pub const event = @import("bt/event.zig");
pub const state = @import("bt/state.zig");
pub const EventHook = @import("bt/EventHook.zig");
pub const CentralReducer = @import("bt/CentralReducer.zig");
pub const PeriphReducer = @import("bt/PeriphReducer.zig");

const EventReceiver = zux_event.EventReceiver;
const root = @This();

host: bt.Host,

pub const addr_len = event.addr_len;
pub const max_name_len = event.max_name_len;
pub const max_adv_data_len = event.max_adv_data_len;
pub const max_notification_len = event.max_notification_len;
pub const Event = event.Event;
pub const CallbackFn = event.CallbackFn;

pub fn init(host: bt.Host) root {
    return .{
        .host = host,
    };
}

pub fn setEventReceiver(self: *root, receiver: *const EventReceiver) void {
    self.host.setEventCallback(@ptrCast(receiver), eventReceiverEmitUpdate);
}

pub fn clearEventReceiver(self: *root) void {
    self.host.clearEventCallback();
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn setAndEmitReportsThroughEventReceiver(testing: anytype) !void {
            const Sink = struct {
                started_count: usize = 0,
                stopped_count: usize = 0,
                found_count: usize = 0,
                central_connected_count: usize = 0,
                central_disconnected_count: usize = 0,
                central_notification_count: usize = 0,
                periph_connected_count: usize = 0,
                periph_disconnected_count: usize = 0,
                periph_mtu_changed_count: usize = 0,
                last_source_id: u32 = 0,
                last_name_len: usize = 0,
                last_adv_len: usize = 0,
                last_rssi: i8 = 0,
                last_central_conn_handle: u16 = 0,
                last_periph_conn_handle: u16 = 0,
                last_notification_attr_handle: u16 = 0,
                last_notification_len: usize = 0,
                last_periph_mtu: u16 = 0,

                fn emitFn(ctx: *anyopaque, value: zux_event.Event) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    switch (value) {
                        .ble_periph_advertising_started => |report| {
                            self.started_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .ble_periph_advertising_stopped => |report| {
                            self.stopped_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .ble_central_found => |report| {
                            self.found_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_name_len = report.name().len;
                            self.last_adv_len = report.advData().len;
                            self.last_rssi = report.rssi;
                        },
                        .ble_central_connected => |report| {
                            self.central_connected_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_central_conn_handle = report.conn_handle;
                        },
                        .ble_central_disconnected => |report| {
                            self.central_disconnected_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_central_conn_handle = report.conn_handle;
                        },
                        .ble_central_notification => |report| {
                            self.central_notification_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_central_conn_handle = report.conn_handle;
                            self.last_notification_attr_handle = report.attr_handle;
                            self.last_notification_len = report.payload().len;
                        },
                        .ble_periph_connected => |report| {
                            self.periph_connected_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_periph_conn_handle = report.conn_handle;
                        },
                        .ble_periph_disconnected => |report| {
                            self.periph_disconnected_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_periph_conn_handle = report.conn_handle;
                        },
                        .ble_periph_mtu_changed => |report| {
                            self.periph_mtu_changed_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_periph_conn_handle = report.conn_handle;
                            self.last_periph_mtu = report.mtu;
                        },
                        else => {},
                    }
                }
            };

            var sink = Sink{};
            const receiver = EventReceiver.init(@ptrCast(&sink), Sink.emitFn);

            var host_impl = TestCaseHost{};
            const host = bt.Host{
                .ptr = @ptrCast(&host_impl),
                .vtable = &host_vtable,
            };
            var adapter = root.init(host);
            adapter.setEventReceiver(&receiver);
            try host_impl.emit();

            try testing.expectEqual(@as(usize, 1), sink.started_count);
            try testing.expectEqual(@as(usize, 1), sink.stopped_count);
            try testing.expectEqual(@as(usize, 1), sink.found_count);
            try testing.expectEqual(@as(usize, 1), sink.central_connected_count);
            try testing.expectEqual(@as(usize, 1), sink.central_disconnected_count);
            try testing.expectEqual(@as(usize, 1), sink.central_notification_count);
            try testing.expectEqual(@as(usize, 1), sink.periph_connected_count);
            try testing.expectEqual(@as(usize, 1), sink.periph_disconnected_count);
            try testing.expectEqual(@as(usize, 1), sink.periph_mtu_changed_count);
            try testing.expectEqual(@as(u32, 41), sink.last_source_id);
            try testing.expectEqual(@as(usize, 10), sink.last_name_len);
            try testing.expectEqual(@as(usize, 7), sink.last_adv_len);
            try testing.expectEqual(@as(i8, -52), sink.last_rssi);
            try testing.expectEqual(@as(u16, 0x0040), sink.last_central_conn_handle);
            try testing.expectEqual(@as(u16, 0x0041), sink.last_periph_conn_handle);
            try testing.expectEqual(@as(u16, 0x0009), sink.last_notification_attr_handle);
            try testing.expectEqual(@as(usize, 3), sink.last_notification_len);
            try testing.expectEqual(@as(u16, 247), sink.last_periph_mtu);

            adapter.clearEventReceiver();
            try testing.expect(host_impl.receiver_ctx == null);
            try testing.expect(host_impl.emit_fn == null);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            TestCase.setAndEmitReportsThroughEventReceiver(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

fn eventReceiverEmitUpdate(ctx: *const anyopaque, source_id: u32, host_event: Event) void {
    const receiver: *const EventReceiver = @ptrCast(@alignCast(ctx));
    const value = event.make(zux_event.Event, source_id, host_event) catch @panic("zux.component.bt received unsupported bt.Host event");
    receiver.emit(value);
}

const DummyCentral = struct {
    pub fn start(_: *@This()) bt.Central.StartError!void {}
    pub fn stop(_: *@This()) void {}
    pub fn startScanning(_: *@This(), _: bt.Central.ScanConfig) bt.Central.ScanError!void {}
    pub fn stopScanning(_: *@This()) void {}
    pub fn connect(_: *@This(), _: bt.Central.BdAddr, _: bt.Central.AddrType, _: bt.Central.ConnParams) bt.Central.ConnectError!bt.Central.ConnectionInfo {
        return error.Unexpected;
    }
    pub fn disconnect(_: *@This(), _: u16) void {}
    pub fn discoverServices(_: *@This(), _: u16, _: []bt.Central.DiscoveredService) bt.Central.GattError!usize {
        return 0;
    }
    pub fn discoverChars(_: *@This(), _: u16, _: u16, _: u16, _: []bt.Central.DiscoveredChar) bt.Central.GattError!usize {
        return 0;
    }
    pub fn gattRead(_: *@This(), _: u16, _: u16, _: []u8) bt.Central.GattError!usize {
        return 0;
    }
    pub fn gattWrite(_: *@This(), _: u16, _: u16, _: []const u8) bt.Central.GattError!void {}
    pub fn gattWriteNoResp(_: *@This(), _: u16, _: u16, _: []const u8) bt.Central.GattError!void {}
    pub fn exchangeMtu(_: *@This(), _: u16, mtu: u16) bt.Central.GattError!u16 {
        return mtu;
    }
    pub fn subscribe(_: *@This(), _: u16, _: u16) bt.Central.GattError!void {}
    pub fn subscribeIndications(_: *@This(), _: u16, _: u16) bt.Central.GattError!void {}
    pub fn unsubscribe(_: *@This(), _: u16, _: u16) bt.Central.GattError!void {}
    pub fn getAttMtu(_: *@This(), _: u16) u16 {
        return bt.Central.DEFAULT_ATT_MTU;
    }
    pub fn getState(_: *@This()) bt.Central.State {
        return .idle;
    }
    pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, bt.Central.Event) void) void {}
    pub fn removeEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, bt.Central.Event) void) void {}
    pub fn getAddr(_: *@This()) ?bt.Central.BdAddr {
        return null;
    }
    pub fn deinit(_: *@This()) void {}
};

const DummyPeripheral = struct {
    pub fn start(_: *@This()) bt.Peripheral.StartError!void {}
    pub fn stop(_: *@This()) void {}
    pub fn startAdvertising(_: *@This(), _: bt.Peripheral.AdvConfig) bt.Peripheral.AdvError!void {}
    pub fn stopAdvertising(_: *@This()) void {}
    pub fn setConfig(_: *@This(), _: bt.Peripheral.GattConfig) void {}
    pub fn setRequestHandler(_: *@This(), _: ?*anyopaque, _: bt.Peripheral.RequestHandlerFn) void {}
    pub fn clearRequestHandler(_: *@This()) void {}
    pub fn notify(_: *@This(), _: u16, _: u16, _: []const u8) bt.Peripheral.GattError!void {}
    pub fn indicate(_: *@This(), _: u16, _: u16, _: []const u8) bt.Peripheral.GattError!void {}
    pub fn disconnect(_: *@This(), _: u16) void {}
    pub fn getState(_: *@This()) bt.Peripheral.State {
        return .idle;
    }
    pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, bt.Peripheral.Event) void) void {}
    pub fn removeEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, bt.Peripheral.Event) void) void {}
    pub fn addSubscriptionHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, bt.Peripheral.SubscriptionInfo) void) void {}
    pub fn removeSubscriptionHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, bt.Peripheral.SubscriptionInfo) void) void {}
    pub fn getAddr(_: *@This()) ?bt.Peripheral.BdAddr {
        return null;
    }
    pub fn deinit(_: *@This()) void {}
};

const host_vtable = bt.Host.VTable{
    .deinit = struct {
        fn call(ptr: *anyopaque) void {
            const self: *TestCaseHost = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
    }.call,
    .central = struct {
        fn call(ptr: *anyopaque) bt.Central {
            const self: *TestCaseHost = @ptrCast(@alignCast(ptr));
            return self.central();
        }
    }.call,
    .peripheral = struct {
        fn call(ptr: *anyopaque) bt.Peripheral {
            const self: *TestCaseHost = @ptrCast(@alignCast(ptr));
            return self.peripheral();
        }
    }.call,
    .setEventCallback = struct {
        fn call(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
            const self: *TestCaseHost = @ptrCast(@alignCast(ptr));
            self.setEventCallback(ctx, emit_fn);
        }
    }.call,
    .clearEventCallback = struct {
        fn call(ptr: *anyopaque) void {
            const self: *TestCaseHost = @ptrCast(@alignCast(ptr));
            self.clearEventCallback();
        }
    }.call,
};

const TestCaseHost = struct {
    receiver_ctx: ?*const anyopaque = null,
    emit_fn: ?CallbackFn = null,
    central_impl: DummyCentral = .{},
    peripheral_impl: DummyPeripheral = .{},

    fn deinit(_: *@This()) void {}

    fn central(self: *@This()) bt.Central {
        return bt.Central.make(&self.central_impl);
    }

    fn peripheral(self: *@This()) bt.Peripheral {
        return bt.Peripheral.make(&self.peripheral_impl);
    }

    fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: CallbackFn) void {
        self.receiver_ctx = ctx;
        self.emit_fn = emit_fn;
    }

    fn clearEventCallback(self: *@This()) void {
        self.receiver_ctx = null;
        self.emit_fn = null;
    }

    fn emit(self: *@This()) !void {
        const receiver_ctx = self.receiver_ctx orelse return error.MissingReceiver;
        const emit_fn = self.emit_fn orelse return error.MissingReceiver;

        emit_fn(receiver_ctx, 41, .{ .peripheral = .{ .advertising_started = {} } });
        emit_fn(receiver_ctx, 41, .{
            .central = .{
                .device_found = blk: {
                    var report = bt.Central.AdvReport{
                        .addr = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
                        .addr_type = .public,
                        .rssi = -52,
                    };
                    @memcpy(report.name[0.."sensor-tag".len], "sensor-tag");
                    report.name_len = "sensor-tag".len;
                    const adv = [_]u8{ 0x02, 0x01, 0x06, 0x03, 0x03, 0xAA, 0xFE };
                    @memcpy(report.data[0..adv.len], &adv);
                    report.data_len = adv.len;
                    break :blk report;
                },
            },
        });
        emit_fn(receiver_ctx, 41, .{
            .central = .{
                .connected = .{
                    .conn_handle = 0x0040,
                    .peer_addr = .{ 1, 2, 3, 4, 5, 6 },
                    .peer_addr_type = .random,
                    .interval = 24,
                    .latency = 1,
                    .timeout = 200,
                },
            },
        });
        emit_fn(receiver_ctx, 41, .{
            .central = .{
                .notification = blk: {
                    var notif = bt.Central.NotificationData{
                        .conn_handle = 0x0040,
                        .attr_handle = 0x0009,
                        .len = 3,
                    };
                    @memcpy(notif.data[0..3], "abc");
                    break :blk notif;
                },
            },
        });
        emit_fn(receiver_ctx, 41, .{
            .central = .{
                .disconnected = 0x0040,
            },
        });
        emit_fn(receiver_ctx, 41, .{
            .peripheral = .{
                .connected = .{
                    .conn_handle = 0x0041,
                    .peer_addr = .{ 6, 5, 4, 3, 2, 1 },
                    .peer_addr_type = .public,
                    .interval = 30,
                    .latency = 0,
                    .timeout = 300,
                },
            },
        });
        emit_fn(receiver_ctx, 41, .{
            .peripheral = .{
                .mtu_changed = .{
                    .conn_handle = 0x0041,
                    .mtu = 247,
                },
            },
        });
        emit_fn(receiver_ctx, 41, .{
            .peripheral = .{
                .disconnected = 0x0041,
            },
        });
        emit_fn(receiver_ctx, 41, .{ .peripheral = .{ .advertising_stopped = {} } });
    }
};
