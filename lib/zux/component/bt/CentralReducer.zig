const bt_event = @import("event.zig");
const bt_state = @import("state.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const testing_api = @import("testing");

const CentralReducer = @This();
const CentralState = bt_state.Central;

pub fn init() CentralReducer {
    return .{};
}

pub fn reduce(self: *CentralReducer, store: anytype, message: Message, emit: Emitter) !usize {
    _ = self;
    _ = emit;

    switch (message.body) {
        .ble_central_found => |value| {
            store.invoke(value, struct {
                fn apply(state: *CentralState, event_value: bt_event.CentralFound) void {
                    state.source_id = event_value.source_id;
                    state.peer_addr = event_value.peer_addr;
                    state.last_rssi = event_value.rssi;
                    state.name_end = event_value.name_end;
                    state.name_buf = event_value.name_buf;
                    state.adv_data_end = event_value.adv_data_end;
                    state.adv_data_buf = event_value.adv_data_buf;
                }
            }.apply);
        },
        .ble_central_connected => |value| {
            store.invoke(value, struct {
                fn apply(state: *CentralState, event_value: bt_event.CentralConnected) void {
                    state.source_id = event_value.source_id;
                    state.connected = true;
                    state.conn_handle = event_value.conn_handle;
                    state.peer_addr = event_value.peer_addr;
                    state.peer_addr_type = event_value.peer_addr_type;
                    state.interval = event_value.interval;
                    state.latency = event_value.latency;
                    state.timeout = event_value.timeout;
                }
            }.apply);
        },
        .ble_central_disconnected => |value| {
            store.invoke(value, struct {
                fn apply(state: *CentralState, event_value: bt_event.CentralDisconnected) void {
                    state.source_id = event_value.source_id;
                    state.connected = false;
                    state.conn_handle = null;
                    state.interval = 0;
                    state.latency = 0;
                    state.timeout = 0;
                }
            }.apply);
        },
        .ble_central_notification => |value| {
            store.invoke(value, struct {
                fn apply(state: *CentralState, event_value: bt_event.CentralNotification) void {
                    state.source_id = event_value.source_id;
                    state.connected = true;
                    state.conn_handle = event_value.conn_handle;
                    state.last_notification_attr_handle = event_value.attr_handle;
                    state.last_notification_len = event_value.data_len;
                    state.last_notification_buf = event_value.data_buf;
                }
            }.apply);
        },
        else => return 0,
    }
    return 0;
}

pub fn deinit(self: *CentralReducer) void {
    _ = self;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn reduceTracksCommonState() !void {
            const embed_std = @import("embed_std");
            const StoreObject = @import("../../store/Object.zig");

            const CentralStore = StoreObject.make(embed_std.std, CentralState, .bt_central);
            var store = CentralStore.init(lib.testing.allocator, .{});
            defer store.deinit();
            var reducer = CentralReducer.init();
            defer reducer.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};
            const emit = Emitter.init(&sink);

            try lib.testing.expectEqual(@as(usize, 0), try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_central_found = .{
                        .source_id = 9,
                        .peer_addr = .{ 1, 2, 3, 4, 5, 6 },
                        .rssi = -48,
                        .name_end = 4,
                        .name_buf = blk: {
                            var buf = [_]u8{0} ** bt_event.max_name_len;
                            @memcpy(buf[0..4], "peer");
                            break :blk buf;
                        },
                        .adv_data_end = 3,
                        .adv_data_buf = blk: {
                            var buf = [_]u8{0} ** bt_event.max_adv_data_len;
                            buf[0] = 0x01;
                            buf[1] = 0x02;
                            buf[2] = 0x03;
                            break :blk buf;
                        },
                    },
                },
            }, emit));
            try lib.testing.expectEqual(@as(usize, 0), try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_central_connected = .{
                        .source_id = 9,
                        .conn_handle = 0x0040,
                        .peer_addr = .{ 1, 2, 3, 4, 5, 6 },
                        .peer_addr_type = .random,
                        .interval = 24,
                        .latency = 1,
                        .timeout = 200,
                    },
                },
            }, emit));
            try lib.testing.expectEqual(@as(usize, 0), try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_central_notification = .{
                        .source_id = 9,
                        .conn_handle = 0x0040,
                        .attr_handle = 0x0025,
                        .data_len = 3,
                        .data_buf = blk: {
                            var buf = [_]u8{0} ** bt_event.max_notification_len;
                            @memcpy(buf[0..3], "abc");
                            break :blk buf;
                        },
                    },
                },
            }, emit));

            store.tick();
            const state = store.get();
            try lib.testing.expectEqual(@as(u32, 9), state.source_id);
            try lib.testing.expect(state.connected);
            try lib.testing.expectEqual(@as(?u16, 0x0040), state.conn_handle);
            try lib.testing.expectEqual(@as(?i8, -48), state.last_rssi);
            try lib.testing.expectEqualStrings("peer", state.name());
            try lib.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03 }, state.advData());
            try lib.testing.expectEqual(@as(?u16, 0x0025), state.last_notification_attr_handle);
            try lib.testing.expectEqualStrings("abc", state.lastNotification());

            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .ble_central_disconnected = .{
                        .source_id = 9,
                        .conn_handle = 0x0040,
                    },
                },
            }, emit);
            store.tick();
            const disconnected = store.get();
            try lib.testing.expect(!disconnected.connected);
            try lib.testing.expectEqual(@as(?u16, null), disconnected.conn_handle);
            try lib.testing.expectEqualStrings("peer", disconnected.name());
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

            TestCase.reduceTracksCommonState() catch |err| {
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
