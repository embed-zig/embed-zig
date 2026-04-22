const embed = @import("embed");
const bt = @import("bt");
const bt_event = @import("event.zig");
const bt_state = @import("state.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const testing_api = @import("testing");

const PeriphReducer = @This();
const PeriphState = bt_state.Periph;

connections: embed.AutoHashMap(u16, Connection),

const Connection = struct {
    peer_addr: [bt_event.addr_len]u8,
    peer_addr_type: bt.Peripheral.AddrType,
    interval: u16,
    latency: u16,
    timeout: u16,
    mtu: ?u16 = null,
};

pub fn init(allocator: embed.mem.Allocator) PeriphReducer {
    return .{
        .connections = embed.AutoHashMap(u16, Connection).init(allocator),
    };
}

pub fn reduce(self: *PeriphReducer, store: anytype, message: Message, emit: Emitter) !usize {
    _ = emit;

    switch (message.body) {
        .ble_periph_advertising_started => |value| {
            const Ctx = struct {
                reducer: *PeriphReducer,
                event_value: bt_event.PeriphAdvertisingStarted,
            };
            const payload: Ctx = .{ .reducer = self, .event_value = value };
            store.invoke(payload, struct {
                fn apply(state: *PeriphState, arg: Ctx) void {
                    state.source_id = arg.event_value.source_id;
                    state.advertising = true;
                    syncConnectionSummary(state, arg.reducer);
                }
            }.apply);
        },
        .ble_periph_advertising_stopped => |value| {
            const Ctx = struct {
                reducer: *PeriphReducer,
                event_value: bt_event.PeriphAdvertisingStopped,
            };
            const payload: Ctx = .{ .reducer = self, .event_value = value };
            store.invoke(payload, struct {
                fn apply(state: *PeriphState, arg: Ctx) void {
                    state.source_id = arg.event_value.source_id;
                    state.advertising = false;
                    syncConnectionSummary(state, arg.reducer);
                }
            }.apply);
        },
        .ble_periph_connected => |value| {
            const gop = try self.connections.getOrPut(value.conn_handle);
            const previous_mtu = if (gop.found_existing) gop.value_ptr.mtu else null;
            gop.value_ptr.* = .{
                .peer_addr = value.peer_addr,
                .peer_addr_type = value.peer_addr_type,
                .interval = value.interval,
                .latency = value.latency,
                .timeout = value.timeout,
                .mtu = previous_mtu,
            };

            const Ctx = struct {
                reducer: *PeriphReducer,
                event_value: bt_event.PeriphConnected,
            };
            const payload: Ctx = .{ .reducer = self, .event_value = value };
            store.invoke(payload, struct {
                fn apply(state: *PeriphState, arg: Ctx) void {
                    state.source_id = arg.event_value.source_id;
                    state.last_connected_conn_handle = arg.event_value.conn_handle;
                    state.last_peer_addr = arg.event_value.peer_addr;
                    state.last_peer_addr_type = arg.event_value.peer_addr_type;
                    state.last_interval = arg.event_value.interval;
                    state.last_latency = arg.event_value.latency;
                    state.last_timeout = arg.event_value.timeout;
                    syncConnectionSummary(state, arg.reducer);
                }
            }.apply);
        },
        .ble_periph_disconnected => |value| {
            _ = self.connections.remove(value.conn_handle);

            const Ctx = struct {
                reducer: *PeriphReducer,
                event_value: bt_event.PeriphDisconnected,
            };
            const payload: Ctx = .{ .reducer = self, .event_value = value };
            store.invoke(payload, struct {
                fn apply(state: *PeriphState, arg: Ctx) void {
                    state.source_id = arg.event_value.source_id;
                    state.last_disconnected_conn_handle = arg.event_value.conn_handle;
                    syncConnectionSummary(state, arg.reducer);
                }
            }.apply);
        },
        .ble_periph_mtu_changed => |value| {
            if (self.connections.getPtr(value.conn_handle)) |connection| {
                connection.mtu = value.mtu;
            }

            const Ctx = struct {
                reducer: *PeriphReducer,
                event_value: bt_event.PeriphMtuChanged,
            };
            const payload: Ctx = .{ .reducer = self, .event_value = value };
            store.invoke(payload, struct {
                fn apply(state: *PeriphState, arg: Ctx) void {
                    state.source_id = arg.event_value.source_id;
                    state.last_mtu_conn_handle = arg.event_value.conn_handle;
                    state.last_mtu = arg.event_value.mtu;
                    syncConnectionSummary(state, arg.reducer);
                }
            }.apply);
        },
        else => return 0,
    }
    return 0;
}

pub fn deinit(self: *PeriphReducer) void {
    self.connections.deinit();
}

fn syncConnectionSummary(state: *PeriphState, self: *PeriphReducer) void {
    const max_count: usize = embed.math.maxInt(u16);
    state.connected_count = @intCast(@min(self.connections.count(), max_count));
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn reduceTracksActiveConnections() !void {
            const embed_std = @import("embed_std");
            const StoreObject = @import("../../store/Object.zig");

            const PeriphStore = StoreObject.make(embed_std.std, PeriphState, .bt_periph);
            var store = PeriphStore.init(lib.testing.allocator, .{});
            defer store.deinit();
            var reducer = PeriphReducer.init(lib.testing.allocator);
            defer reducer.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};
            const emit = Emitter.init(&sink);

            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_periph_advertising_started = .{
                        .source_id = 21,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_periph_connected = .{
                        .source_id = 21,
                        .conn_handle = 0x0041,
                        .peer_addr = .{ 6, 5, 4, 3, 2, 1 },
                        .peer_addr_type = .public,
                        .interval = 30,
                        .latency = 0,
                        .timeout = 300,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_periph_connected = .{
                        .source_id = 21,
                        .conn_handle = 0x0041,
                        .peer_addr = .{ 6, 5, 4, 3, 2, 1 },
                        .peer_addr_type = .public,
                        .interval = 30,
                        .latency = 0,
                        .timeout = 300,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_periph_connected = .{
                        .source_id = 21,
                        .conn_handle = 0x0042,
                        .peer_addr = .{ 1, 2, 3, 4, 5, 6 },
                        .peer_addr_type = .random,
                        .interval = 24,
                        .latency = 1,
                        .timeout = 200,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_periph_mtu_changed = .{
                        .source_id = 21,
                        .conn_handle = 0x0042,
                        .mtu = 247,
                    },
                },
            }, emit);

            store.tick();
            const state = store.get();
            try lib.testing.expectEqual(@as(u32, 21), state.source_id);
            try lib.testing.expect(state.connected());
            try lib.testing.expect(state.advertising);
            try lib.testing.expectEqual(@as(u16, 2), state.connected_count);
            try lib.testing.expectEqual(@as(?u16, 0x0042), state.last_connected_conn_handle);
            try lib.testing.expectEqual(@as(?u16, 0x0042), state.last_mtu_conn_handle);
            try lib.testing.expectEqual(@as(?u16, 247), state.last_mtu);

            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_periph_disconnected = .{
                        .source_id = 21,
                        .conn_handle = 0x0099,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_periph_disconnected = .{
                        .source_id = 21,
                        .conn_handle = 0x0041,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_periph_disconnected = .{
                        .source_id = 21,
                        .conn_handle = 0x0041,
                    },
                },
            }, emit);
            store.tick();
            const partially_connected = store.get();
            try lib.testing.expect(partially_connected.connected());
            try lib.testing.expectEqual(@as(u16, 1), partially_connected.connected_count);
            try lib.testing.expectEqual(@as(?u16, 0x0041), partially_connected.last_disconnected_conn_handle);

            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_periph_advertising_stopped = .{
                        .source_id = 21,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_periph_disconnected = .{
                        .source_id = 21,
                        .conn_handle = 0x0042,
                    },
                },
            }, emit);
            store.tick();
            const disconnected = store.get();
            try lib.testing.expect(!disconnected.connected());
            try lib.testing.expectEqual(@as(u16, 0), disconnected.connected_count);
            try lib.testing.expect(!disconnected.advertising);
            try lib.testing.expectEqual(@as(?u16, 0x0042), disconnected.last_disconnected_conn_handle);
            try lib.testing.expectEqual(@as(?u16, 247), disconnected.last_mtu);
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

            TestCase.reduceTracksActiveConnections() catch |err| {
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
