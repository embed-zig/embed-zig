const Context = @import("event/Context.zig");
const event = @import("event.zig");
const testing_api = @import("testing");

const EventReceiver = event.EventReceiver;
const Wifi = @This();

pub const max_ssid_len: usize = 32;
pub const bssid_len: usize = 6;

ptr: *anyopaque,
vtable: *const VTable,

pub const Security = enum {
    unknown,
    open,
    wep,
    wpa,
    wpa2,
    wpa3,
};

pub const StaScanResultEvent = struct {
    pub const kind = .wifi_sta_scan_result;

    source_id: u32,
    ssid_end: u8,
    ssid_buf: [max_ssid_len]u8,
    bssid: [bssid_len]u8,
    channel: u8,
    rssi: i16,
    security: Security,
    ctx: Context.Type = null,

    pub fn ssid(self: *const @This()) []const u8 {
        return self.ssid_buf[0..self.ssid_end];
    }
};

pub const StaConnectedEvent = struct {
    pub const kind = .wifi_sta_connected;

    source_id: u32,
    ssid_end: u8,
    ssid_buf: [max_ssid_len]u8,
    bssid: [bssid_len]u8,
    channel: u8,
    ctx: Context.Type = null,

    pub fn ssid(self: *const @This()) []const u8 {
        return self.ssid_buf[0..self.ssid_end];
    }
};

pub const StaDisconnectedEvent = struct {
    pub const kind = .wifi_sta_disconnected;

    source_id: u32,
    reason: u16,
    ctx: Context.Type = null,
};

pub const StaScanResult = struct {
    source_id: u32,
    ssid: []const u8,
    bssid: [bssid_len]u8,
    channel: u8,
    rssi: i16,
    security: Security,
    ctx: Context.Type = null,
};

pub const StaConnected = struct {
    source_id: u32,
    ssid: []const u8,
    bssid: [bssid_len]u8,
    channel: u8,
    ctx: Context.Type = null,
};

pub const StaDisconnected = struct {
    source_id: u32,
    reason: u16,
    ctx: Context.Type = null,
};

pub const Update = union(enum) {
    sta_scan_result: StaScanResult,
    sta_connected: StaConnected,
    sta_disconnected: StaDisconnected,
};

pub const CallbackFn = *const fn (ctx: *const anyopaque, update: Update) void;

pub const VTable = struct {
    setEventCallback: *const fn (ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void,
    clearEventCallback: *const fn (ptr: *anyopaque) void,
};

pub fn makeEvent(value: Update) !event.Event {
    return switch (value) {
        .sta_scan_result => |report| .{
            .wifi_sta_scan_result = .{
                .source_id = report.source_id,
                .ssid_end = try copySsid(report.ssid),
                .ssid_buf = try copySsidBuf(report.ssid),
                .bssid = report.bssid,
                .channel = report.channel,
                .rssi = report.rssi,
                .security = report.security,
                .ctx = report.ctx,
            },
        },
        .sta_connected => |report| .{
            .wifi_sta_connected = .{
                .source_id = report.source_id,
                .ssid_end = try copySsid(report.ssid),
                .ssid_buf = try copySsidBuf(report.ssid),
                .bssid = report.bssid,
                .channel = report.channel,
                .ctx = report.ctx,
            },
        },
        .sta_disconnected => |report| .{
            .wifi_sta_disconnected = .{
                .source_id = report.source_id,
                .reason = report.reason,
                .ctx = report.ctx,
            },
        },
    };
}

fn copySsid(ssid: []const u8) !u8 {
    if (ssid.len > max_ssid_len) return error.InvalidSsidLength;
    return @intCast(ssid.len);
}

fn copySsidBuf(ssid: []const u8) ![max_ssid_len]u8 {
    if (ssid.len > max_ssid_len) return error.InvalidSsidLength;

    var buf = [_]u8{0} ** max_ssid_len;
    @memcpy(buf[0..ssid.len], ssid);
    return buf;
}

pub fn setEventReceiver(self: Wifi, receiver: *const EventReceiver) void {
    self.vtable.setEventCallback(self.ptr, @ptrCast(receiver), eventReceiverEmitUpdate);
}

pub fn clearEventReceiver(self: Wifi) void {
    self.vtable.clearEventCallback(self.ptr);
}

pub fn init(comptime T: type, impl: *T) Wifi {
    comptime {
        _ = @as(*const fn (*T, *const anyopaque, CallbackFn) void, &T.setEventCallback);
        _ = @as(*const fn (*T) void, &T.clearEventCallback);
    }

    const gen = struct {
        fn setEventCallbackFn(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.setEventCallback(ctx, emit_fn);
        }

        fn clearEventCallbackFn(ptr: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.clearEventCallback();
        }

        const vtable = VTable{
            .setEventCallback = setEventCallbackFn,
            .clearEventCallback = clearEventCallbackFn,
        };
    };

    return .{
        .ptr = @ptrCast(impl),
        .vtable = &gen.vtable,
    };
}

fn eventReceiverEmitUpdate(ctx: *const anyopaque, update: Update) void {
    const receiver: *const EventReceiver = @ptrCast(@alignCast(ctx));
    const value = makeEvent(update) catch @panic("zux.Wifi received invalid adapter event");
    receiver.emit(value);
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn setAndEmitStaReportsThroughEventReceiver(testing: anytype) !void {
            const Sink = struct {
                scan_count: usize = 0,
                connected_count: usize = 0,
                disconnected_count: usize = 0,
                last_source_id: u32 = 0,
                last_ssid_len: usize = 0,
                last_reason: u16 = 0,

                fn emitFn(ctx: *anyopaque, value: event.Event) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    switch (value) {
                        .wifi_sta_scan_result => |report| {
                            self.scan_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_ssid_len = report.ssid().len;
                        },
                        .wifi_sta_connected => |report| {
                            self.connected_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_ssid_len = report.ssid().len;
                        },
                        .wifi_sta_disconnected => |report| {
                            self.disconnected_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_reason = report.reason;
                        },
                        else => {},
                    }
                }
            };

            const Impl = struct {
                receiver_ctx: ?*const anyopaque = null,
                emit_fn: ?CallbackFn = null,

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

                    emit_fn(receiver_ctx, .{
                        .sta_scan_result = .{
                            .source_id = 31,
                            .ssid = "wifi-lab",
                            .bssid = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
                            .channel = 6,
                            .rssi = -47,
                            .security = .wpa2,
                        },
                    });
                    emit_fn(receiver_ctx, .{
                        .sta_connected = .{
                            .source_id = 31,
                            .ssid = "wifi-lab",
                            .bssid = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
                            .channel = 6,
                        },
                    });
                    emit_fn(receiver_ctx, .{
                        .sta_disconnected = .{
                            .source_id = 31,
                            .reason = 7,
                        },
                    });
                }
            };

            var sink = Sink{};
            const receiver = EventReceiver.init(@ptrCast(&sink), Sink.emitFn);

            var impl = Impl{};
            const wifi = Wifi.init(Impl, &impl);
            wifi.setEventReceiver(&receiver);
            try impl.emit();

            try testing.expectEqual(@as(usize, 1), sink.scan_count);
            try testing.expectEqual(@as(usize, 1), sink.connected_count);
            try testing.expectEqual(@as(usize, 1), sink.disconnected_count);
            try testing.expectEqual(@as(u32, 31), sink.last_source_id);
            try testing.expectEqual(@as(usize, 8), sink.last_ssid_len);
            try testing.expectEqual(@as(u16, 7), sink.last_reason);

            wifi.clearEventReceiver();
            try testing.expect(impl.receiver_ctx == null);
            try testing.expect(impl.emit_fn == null);
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

            TestCase.setAndEmitStaReportsThroughEventReceiver(testing) catch |err| {
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
