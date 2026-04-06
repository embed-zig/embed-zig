const bt = @import("bt");
const Context = @import("event/Context.zig");
const event = @import("event.zig");
const testing_api = @import("testing");

const EventReceiver = event.EventReceiver;
const Bt = @This();

pub const addr_len: usize = bt.Host.addr_len;
pub const max_name_len: usize = bt.Host.max_name_len;
pub const max_adv_data_len: usize = bt.Host.max_adv_data_len;
pub const max_notification_len: usize = bt.Central.MAX_NOTIFICATION_VALUE_LEN;

host: bt.Host,

pub const PeriphAdvertisingStartedEvent = struct {
    pub const kind = .ble_periph_advertising_started;

    source_id: u32,
    ctx: Context.Type = null,
};

pub const PeriphAdvertisingStoppedEvent = struct {
    pub const kind = .ble_periph_advertising_stopped;

    source_id: u32,
    ctx: Context.Type = null,
};

pub const CentralFoundEvent = struct {
    pub const kind = .ble_central_found;

    source_id: u32,
    peer_addr: [addr_len]u8,
    rssi: i8,
    name_end: u8,
    name_buf: [max_name_len]u8,
    adv_data_end: u8,
    adv_data_buf: [max_adv_data_len]u8,
    ctx: Context.Type = null,

    pub fn name(self: *const @This()) []const u8 {
        return self.name_buf[0..self.name_end];
    }

    pub fn advData(self: *const @This()) []const u8 {
        return self.adv_data_buf[0..self.adv_data_end];
    }
};

pub const CentralConnectedEvent = struct {
    pub const kind = .ble_central_connected;

    source_id: u32,
    conn_handle: u16,
    peer_addr: [addr_len]u8,
    peer_addr_type: bt.Central.AddrType,
    interval: u16,
    latency: u16,
    timeout: u16,
    ctx: Context.Type = null,
};

pub const CentralDisconnectedEvent = struct {
    pub const kind = .ble_central_disconnected;

    source_id: u32,
    conn_handle: u16,
    ctx: Context.Type = null,
};

pub const CentralNotificationEvent = struct {
    pub const kind = .ble_central_notification;

    source_id: u32,
    conn_handle: u16,
    attr_handle: u16,
    data_len: u16,
    data_buf: [max_notification_len]u8,
    ctx: Context.Type = null,

    pub fn payload(self: *const @This()) []const u8 {
        return self.data_buf[0..self.data_len];
    }
};

pub const PeriphConnectedEvent = struct {
    pub const kind = .ble_periph_connected;

    source_id: u32,
    conn_handle: u16,
    peer_addr: [addr_len]u8,
    peer_addr_type: bt.Peripheral.AddrType,
    interval: u16,
    latency: u16,
    timeout: u16,
    ctx: Context.Type = null,
};

pub const PeriphDisconnectedEvent = struct {
    pub const kind = .ble_periph_disconnected;

    source_id: u32,
    conn_handle: u16,
    ctx: Context.Type = null,
};

pub const PeriphMtuChangedEvent = struct {
    pub const kind = .ble_periph_mtu_changed;

    source_id: u32,
    conn_handle: u16,
    mtu: u16,
    ctx: Context.Type = null,
};

pub const Event = bt.Host.Event;
pub const CallbackFn = bt.Host.CallbackFn;

pub fn makeEvent(source_id: u32, bt_event: Event) !event.Event {
    return switch (bt_event) {
        .central => |central_event| switch (central_event) {
            .device_found => |report| .{
                .ble_central_found = .{
                    .source_id = source_id,
                    .peer_addr = report.addr,
                    .rssi = report.rssi,
                    .name_end = try copyNameLen(if (report.name_len == 0) null else report.getName()),
                    .name_buf = try copyNameBuf(if (report.name_len == 0) null else report.getName()),
                    .adv_data_end = try copyAdvDataLen(if (report.data_len == 0) null else report.getData()),
                    .adv_data_buf = try copyAdvDataBuf(if (report.data_len == 0) null else report.getData()),
                    .ctx = null,
                },
            },
            .connected => |info| .{
                .ble_central_connected = .{
                    .source_id = source_id,
                    .conn_handle = info.conn_handle,
                    .peer_addr = info.peer_addr,
                    .peer_addr_type = info.peer_addr_type,
                    .interval = info.interval,
                    .latency = info.latency,
                    .timeout = info.timeout,
                    .ctx = null,
                },
            },
            .disconnected => |conn_handle| .{
                .ble_central_disconnected = .{
                    .source_id = source_id,
                    .conn_handle = conn_handle,
                    .ctx = null,
                },
            },
            .notification => |notif| .{
                .ble_central_notification = .{
                    .source_id = source_id,
                    .conn_handle = notif.conn_handle,
                    .attr_handle = notif.attr_handle,
                    .data_len = notif.len,
                    .data_buf = copyNotificationBuf(notif.payload()),
                    .ctx = null,
                },
            },
        },
        .peripheral => |peripheral_event| switch (peripheral_event) {
            .advertising_started => .{
                .ble_periph_advertising_started = .{
                    .source_id = source_id,
                    .ctx = null,
                },
            },
            .advertising_stopped => .{
                .ble_periph_advertising_stopped = .{
                    .source_id = source_id,
                    .ctx = null,
                },
            },
            .connected => |info| .{
                .ble_periph_connected = .{
                    .source_id = source_id,
                    .conn_handle = info.conn_handle,
                    .peer_addr = info.peer_addr,
                    .peer_addr_type = info.peer_addr_type,
                    .interval = info.interval,
                    .latency = info.latency,
                    .timeout = info.timeout,
                    .ctx = null,
                },
            },
            .disconnected => |conn_handle| .{
                .ble_periph_disconnected = .{
                    .source_id = source_id,
                    .conn_handle = conn_handle,
                    .ctx = null,
                },
            },
            .mtu_changed => |info| .{
                .ble_periph_mtu_changed = .{
                    .source_id = source_id,
                    .conn_handle = info.conn_handle,
                    .mtu = info.mtu,
                    .ctx = null,
                },
            },
        },
    };
}

fn copyNameLen(name: ?[]const u8) !u8 {
    const value = name orelse return 0;
    if (value.len > max_name_len) return error.InvalidPeerNameLength;
    return @intCast(value.len);
}

fn copyNameBuf(name: ?[]const u8) ![max_name_len]u8 {
    const value = name orelse return [_]u8{0} ** max_name_len;
    if (value.len > max_name_len) return error.InvalidPeerNameLength;

    var buf = [_]u8{0} ** max_name_len;
    @memcpy(buf[0..value.len], value);
    return buf;
}

fn copyAdvDataLen(data: ?[]const u8) !u8 {
    const value = data orelse return 0;
    if (value.len > max_adv_data_len) return error.InvalidAdvDataLength;
    return @intCast(value.len);
}

fn copyAdvDataBuf(data: ?[]const u8) ![max_adv_data_len]u8 {
    const value = data orelse return [_]u8{0} ** max_adv_data_len;
    if (value.len > max_adv_data_len) return error.InvalidAdvDataLength;

    var buf = [_]u8{0} ** max_adv_data_len;
    @memcpy(buf[0..value.len], value);
    return buf;
}

fn copyNotificationBuf(payload: []const u8) [max_notification_len]u8 {
    var buf = [_]u8{0} ** max_notification_len;
    @memcpy(buf[0..payload.len], payload);
    return buf;
}

pub fn setEventReceiver(self: *Bt, receiver: *const EventReceiver) void {
    self.host.setEventCallback(@ptrCast(receiver), eventReceiverEmitUpdate);
}

pub fn clearEventReceiver(self: *Bt) void {
    self.host.clearEventCallback();
}

pub fn init(host: bt.Host) Bt {
    return .{
        .host = host,
    };
}

fn eventReceiverEmitUpdate(ctx: *const anyopaque, source_id: u32, bt_event: Event) void {
    const receiver: *const EventReceiver = @ptrCast(@alignCast(ctx));
    const value = makeEvent(source_id, bt_event) catch @panic("zux.Bt received unsupported bt.Host event");
    receiver.emit(value);
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

                fn emitFn(ctx: *anyopaque, value: event.Event) void {
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

            const HostImpl = struct {
                receiver_ctx: ?*const anyopaque = null,
                emit_fn: ?CallbackFn = null,
                central_impl: DummyCentral = .{},
                peripheral_impl: DummyPeripheral = .{},

                pub fn deinit(_: *@This()) void {}

                pub fn central(self: *@This()) bt.Central {
                    return bt.Central.make(&self.central_impl);
                }

                pub fn peripheral(self: *@This()) bt.Peripheral {
                    return bt.Peripheral.make(&self.peripheral_impl);
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

            const host_vtable = bt.Host.VTable{
                .deinit = struct {
                    fn call(ptr: *anyopaque) void {
                        const self: *HostImpl = @ptrCast(@alignCast(ptr));
                        self.deinit();
                    }
                }.call,
                .central = struct {
                    fn call(ptr: *anyopaque) bt.Central {
                        const self: *HostImpl = @ptrCast(@alignCast(ptr));
                        return self.central();
                    }
                }.call,
                .peripheral = struct {
                    fn call(ptr: *anyopaque) bt.Peripheral {
                        const self: *HostImpl = @ptrCast(@alignCast(ptr));
                        return self.peripheral();
                    }
                }.call,
                .setEventCallback = struct {
                    fn call(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
                        const self: *HostImpl = @ptrCast(@alignCast(ptr));
                        self.setEventCallback(ctx, emit_fn);
                    }
                }.call,
                .clearEventCallback = struct {
                    fn call(ptr: *anyopaque) void {
                        const self: *HostImpl = @ptrCast(@alignCast(ptr));
                        self.clearEventCallback();
                    }
                }.call,
            };

            var sink = Sink{};
            const receiver = EventReceiver.init(@ptrCast(&sink), Sink.emitFn);

            var host_impl = HostImpl{};
            const host = bt.Host{
                .ptr = @ptrCast(&host_impl),
                .vtable = &host_vtable,
            };
            var bt_adapter = Bt.init(host);
            bt_adapter.setEventReceiver(&receiver);
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

            bt_adapter.clearEventReceiver();
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
