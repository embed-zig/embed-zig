const modem_event = @import("event.zig");
const modem_state = @import("state.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const testing_api = @import("testing");

const Reducer = @This();
const ModemState = modem_state.Modem;

pub fn init() Reducer {
    return .{};
}

pub fn reduce(self: *Reducer, store: anytype, message: Message, emit: Emitter) !usize {
    _ = self;
    _ = emit;

    switch (message.body) {
        .modem_sim_state_changed => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.SimStateChanged) void {
                    state.source_id = event_value.source_id;
                    state.sim = event_value.sim;
                }
            }.apply);
        },
        .modem_registration_changed => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.RegistrationChanged) void {
                    state.source_id = event_value.source_id;
                    state.registration = event_value.registration;
                }
            }.apply);
        },
        .modem_packet_state_changed => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.PacketStateChanged) void {
                    state.source_id = event_value.source_id;
                    state.packet = event_value.packet;
                }
            }.apply);
        },
        .modem_signal_changed => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.SignalChanged) void {
                    state.source_id = event_value.source_id;
                    state.signal = event_value.signal;
                }
            }.apply);
        },
        .modem_apn_changed => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.ApnChanged) void {
                    state.source_id = event_value.source_id;
                    state.apn_end = event_value.apn_end;
                    state.apn_buf = event_value.apn_buf;
                }
            }.apply);
        },
        else => return 0,
    }
    return 0;
}

pub fn deinit(self: *Reducer) void {
    _ = self;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn reduceTracksModemState() !void {
            const embed_std = @import("embed_std");
            const StoreObject = @import("../../store/Object.zig");

            const ModemStore = StoreObject.make(embed_std.std, ModemState, .modem);
            var store = ModemStore.init(lib.testing.allocator, .{});
            defer store.deinit();
            var reducer = Reducer.init();
            defer reducer.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};
            const emit = Emitter.init(&sink);

            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .modem_sim_state_changed = .{
                        .source_id = 51,
                        .sim = .ready,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .modem_registration_changed = .{
                        .source_id = 51,
                        .registration = .home,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .modem_packet_state_changed = .{
                        .source_id = 51,
                        .packet = .connected,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .modem_signal_changed = .{
                        .source_id = 51,
                        .signal = .{
                            .rssi_dbm = -73,
                            .ber = 3,
                            .rat = .lte,
                        },
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .modem_apn_changed = .{
                        .source_id = 51,
                        .apn_end = 8,
                        .apn_buf = blk: {
                            var buf = [_]u8{0} ** modem_event.max_apn_len;
                            @memcpy(buf[0..8], "internet");
                            break :blk buf;
                        },
                    },
                },
            }, emit);

            store.tick();
            const state = store.get();
            try lib.testing.expectEqual(@as(u32, 51), state.source_id);
            try lib.testing.expectEqual(modem_event.SimState.ready, state.sim);
            try lib.testing.expectEqual(modem_event.RegistrationState.home, state.registration);
            try lib.testing.expectEqual(modem_event.PacketState.connected, state.packet);
            try lib.testing.expectEqual(@as(?i16, -73), state.signal.?.rssi_dbm);
            try lib.testing.expectEqual(modem_event.Rat.lte, state.signal.?.rat);
            try lib.testing.expectEqualStrings("internet", state.apn());
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

            TestCase.reduceTracksModemState() catch |err| {
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
