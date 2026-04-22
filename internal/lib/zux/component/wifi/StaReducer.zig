const wifi_event = @import("event.zig");
const wifi_state = @import("state.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const testing_api = @import("testing");

const StaReducer = @This();
const StaState = wifi_state.Sta;
const Addr = wifi_event.Addr;

pub fn init() StaReducer {
    return .{};
}

pub fn reduce(self: *StaReducer, store: anytype, message: Message, emit: Emitter) !usize {
    _ = self;
    _ = emit;

    switch (message.body) {
        .wifi_sta_scan_result => |value| {
            store.invoke(value, struct {
                fn apply(state: *StaState, event_value: wifi_event.StaScanResult) void {
                    state.source_id = event_value.source_id;
                    state.scanning = true;
                    state.ssid_end = event_value.ssid_end;
                    state.ssid_buf = event_value.ssid_buf;
                    state.bssid = event_value.bssid;
                    state.channel = event_value.channel;
                    state.last_rssi = event_value.rssi;
                    state.security = event_value.security;
                }
            }.apply);
        },
        .wifi_sta_connected => |value| {
            store.invoke(value, struct {
                fn apply(state: *StaState, event_value: wifi_event.StaConnected) void {
                    state.source_id = event_value.source_id;
                    state.scanning = false;
                    state.connected = true;
                    state.has_ip = false;
                    state.ssid_end = event_value.ssid_end;
                    state.ssid_buf = event_value.ssid_buf;
                    state.bssid = event_value.bssid;
                    state.channel = event_value.channel;
                    state.last_rssi = event_value.rssi;
                    state.security = event_value.security;
                    state.address = null;
                    state.gateway = null;
                    state.netmask = null;
                    state.dns1 = null;
                    state.dns2 = null;
                }
            }.apply);
        },
        .wifi_sta_disconnected => |value| {
            store.invoke(value, struct {
                fn apply(state: *StaState, event_value: wifi_event.StaDisconnected) void {
                    state.source_id = event_value.source_id;
                    state.scanning = false;
                    state.connected = false;
                    state.has_ip = false;
                    state.address = null;
                    state.gateway = null;
                    state.netmask = null;
                    state.dns1 = null;
                    state.dns2 = null;
                    state.last_disconnect_reason = event_value.reason;
                }
            }.apply);
        },
        .wifi_sta_got_ip => |value| {
            store.invoke(value, struct {
                fn apply(state: *StaState, event_value: wifi_event.StaGotIp) void {
                    state.source_id = event_value.source_id;
                    state.connected = true;
                    state.has_ip = true;
                    state.address = event_value.address;
                    state.gateway = event_value.gateway;
                    state.netmask = event_value.netmask;
                    state.dns1 = event_value.dns1;
                    state.dns2 = event_value.dns2;
                }
            }.apply);
        },
        .wifi_sta_lost_ip => |value| {
            store.invoke(value, struct {
                fn apply(state: *StaState, event_value: wifi_event.StaLostIp) void {
                    state.source_id = event_value.source_id;
                    state.has_ip = false;
                    state.address = null;
                    state.gateway = null;
                    state.netmask = null;
                    state.dns1 = null;
                    state.dns2 = null;
                }
            }.apply);
        },
        else => return 0,
    }
    return 0;
}

pub fn deinit(self: *StaReducer) void {
    _ = self;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn reduceTracksStationState() !void {
            const embed_std = @import("embed_std");
            const StoreObject = @import("../../store/Object.zig");

            const StaStore = StoreObject.make(embed_std.std, StaState, .wifi_sta);
            var store = StaStore.init(lib.testing.allocator, .{});
            defer store.deinit();
            var reducer = StaReducer.init();
            defer reducer.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};
            const emit = Emitter.init(&sink);

            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .wifi_sta_scan_result = .{
                        .source_id = 31,
                        .ssid_end = 8,
                        .ssid_buf = blk: {
                            var buf = [_]u8{0} ** wifi_event.max_ssid_len;
                            @memcpy(buf[0..8], "wifi-lab");
                            break :blk buf;
                        },
                        .bssid = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
                        .channel = 6,
                        .rssi = -47,
                        .security = .wpa2,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .wifi_sta_connected = .{
                        .source_id = 31,
                        .ssid_end = 8,
                        .ssid_buf = blk: {
                            var buf = [_]u8{0} ** wifi_event.max_ssid_len;
                            @memcpy(buf[0..8], "wifi-lab");
                            break :blk buf;
                        },
                        .bssid = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
                        .channel = 6,
                        .rssi = -41,
                        .security = .wpa2,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .wifi_sta_got_ip = .{
                        .source_id = 31,
                        .address = Addr.from4(.{ 192, 168, 4, 2 }),
                        .gateway = Addr.from4(.{ 192, 168, 4, 1 }),
                        .netmask = Addr.from4(.{ 255, 255, 255, 0 }),
                        .dns1 = Addr.from4(.{ 1, 1, 1, 1 }),
                        .dns2 = Addr.from4(.{ 8, 8, 8, 8 }),
                    },
                },
            }, emit);

            store.tick();
            const connected = store.get();
            try lib.testing.expect(connected.connected);
            try lib.testing.expect(connected.has_ip);
            try lib.testing.expectEqual(@as(u32, 31), connected.source_id);
            try lib.testing.expectEqualStrings("wifi-lab", connected.ssid());
            try lib.testing.expectEqual(@as(?i16, -41), connected.last_rssi);
            try lib.testing.expectEqual(Addr.from4(.{ 192, 168, 4, 2 }), connected.address.?);
            try lib.testing.expectEqual(Addr.from4(.{ 1, 1, 1, 1 }), connected.dns1.?);

            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .wifi_sta_lost_ip = .{
                        .source_id = 31,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .wifi_sta_disconnected = .{
                        .source_id = 31,
                        .reason = 7,
                    },
                },
            }, emit);
            store.tick();
            const disconnected = store.get();
            try lib.testing.expect(!disconnected.connected);
            try lib.testing.expect(!disconnected.has_ip);
            try lib.testing.expectEqual(@as(?u16, 7), disconnected.last_disconnect_reason);
            try lib.testing.expectEqual(@as(?Addr, null), disconnected.address);
            try lib.testing.expectEqualStrings("wifi-lab", disconnected.ssid());
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

            TestCase.reduceTracksStationState() catch |err| {
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
