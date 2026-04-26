const modem_event = @import("event.zig");
const ModemState = @import("State.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const glib = @import("glib");

const Reducer = @This();

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
        .modem_network_registration_changed => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.NetworkRegistrationChanged) void {
                    state.source_id = event_value.source_id;
                    state.registration = event_value.registration;
                }
            }.apply);
        },
        .modem_data_packet_state_changed => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.DataPacketStateChanged) void {
                    state.source_id = event_value.source_id;
                    state.packet = event_value.packet;
                }
            }.apply);
        },
        .modem_network_signal_changed => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.NetworkSignalChanged) void {
                    state.source_id = event_value.source_id;
                    state.signal = event_value.signal;
                }
            }.apply);
        },
        .modem_data_apn_changed => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.DataApnChanged) void {
                    state.source_id = event_value.source_id;
                    state.apn_end = event_value.apn_end;
                    state.apn_buf = event_value.apn_buf;
                }
            }.apply);
        },
        .modem_call_incoming => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.CallIncoming) void {
                    state.source_id = event_value.source_id;
                    state.call = .{
                        .call_id = event_value.call_id,
                        .direction = event_value.direction,
                        .state = .incoming,
                        .end_reason = null,
                        .number_end = event_value.number_end,
                        .number_buf = event_value.number_buf,
                    };
                }
            }.apply);
        },
        .modem_call_state_changed => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.CallStateChanged) void {
                    state.source_id = event_value.source_id;
                    state.call = .{
                        .call_id = event_value.call_id,
                        .direction = event_value.direction,
                        .state = event_value.state,
                        .end_reason = null,
                        .number_end = event_value.number_end,
                        .number_buf = event_value.number_buf,
                    };
                }
            }.apply);
        },
        .modem_call_ended => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.CallEnded) void {
                    const previous_call = state.call;
                    state.source_id = event_value.source_id;
                    state.call = .{
                        .call_id = event_value.call_id,
                        .direction = if (previous_call != null and previous_call.?.call_id == event_value.call_id)
                            previous_call.?.direction
                        else
                            .incoming,
                        .state = null,
                        .end_reason = event_value.reason,
                        .number_end = if (previous_call != null and previous_call.?.call_id == event_value.call_id)
                            previous_call.?.number_end
                        else
                            0,
                        .number_buf = if (previous_call != null and previous_call.?.call_id == event_value.call_id)
                            previous_call.?.number_buf
                        else
                            [_]u8{0} ** modem_event.max_phone_number_len,
                    };
                }
            }.apply);
        },
        .modem_sms_received => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.SmsReceived) void {
                    state.source_id = event_value.source_id;
                    state.sms = .{
                        .index = event_value.index,
                        .storage = event_value.storage,
                        .sender_end = event_value.sender_end,
                        .sender_buf = event_value.sender_buf,
                        .text_end = event_value.text_end,
                        .text_buf = event_value.text_buf,
                        .encoding = event_value.encoding,
                    };
                }
            }.apply);
        },
        .modem_gnss_state_changed => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.GnssStateChanged) void {
                    state.source_id = event_value.source_id;
                    state.gnss_state = event_value.state;
                    if (event_value.state != .fixed) {
                        state.gnss_fix = null;
                    }
                }
            }.apply);
        },
        .modem_gnss_fix_changed => |value| {
            store.invoke(value, struct {
                fn apply(state: *ModemState, event_value: modem_event.GnssFixChanged) void {
                    state.source_id = event_value.source_id;
                    state.gnss_state = .fixed;
                    state.gnss_fix = event_value.fix;
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

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn reduceTracksModemState() !void {
            const StoreObject = @import("../../store/Object.zig");

            const ModemStore = StoreObject.make(grt, ModemState, .modem);
            var store = ModemStore.init(grt.std.testing.allocator, .{});
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
                    .modem_network_registration_changed = .{
                        .source_id = 51,
                        .registration = .home,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .modem_data_packet_state_changed = .{
                        .source_id = 51,
                        .packet = .connected,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .modem_network_signal_changed = .{
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
                    .modem_data_apn_changed = .{
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
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .modem_call_incoming = .{
                        .source_id = 51,
                        .call_id = 3,
                        .direction = .incoming,
                        .number_end = 5,
                        .number_buf = blk: {
                            var buf = [_]u8{0} ** modem_event.max_phone_number_len;
                            @memcpy(buf[0..5], "10086");
                            break :blk buf;
                        },
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .modem_call_state_changed = .{
                        .source_id = 51,
                        .call_id = 3,
                        .direction = .incoming,
                        .state = .active,
                        .number_end = 5,
                        .number_buf = blk: {
                            var buf = [_]u8{0} ** modem_event.max_phone_number_len;
                            @memcpy(buf[0..5], "10086");
                            break :blk buf;
                        },
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .modem_call_ended = .{
                        .source_id = 51,
                        .call_id = 3,
                        .reason = .remote_hangup,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .modem_sms_received = .{
                        .source_id = 51,
                        .index = 9,
                        .storage = .sim,
                        .sender_end = 5,
                        .sender_buf = blk: {
                            var buf = [_]u8{0} ** modem_event.max_phone_number_len;
                            @memcpy(buf[0..5], "10010");
                            break :blk buf;
                        },
                        .text_end = 2,
                        .text_buf = blk: {
                            var buf = [_]u8{0} ** modem_event.max_sms_text_len;
                            @memcpy(buf[0..2], "hi");
                            break :blk buf;
                        },
                        .encoding = .utf8,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .modem_gnss_state_changed = .{
                        .source_id = 51,
                        .state = .acquiring,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .modem_gnss_fix_changed = .{
                        .source_id = 51,
                        .fix = .{
                            .quality = .three_d,
                            .latitude_deg = 31.2304,
                            .longitude_deg = 121.4737,
                            .satellites_in_view = 12,
                            .satellites_used = 8,
                        },
                    },
                },
            }, emit);

            store.tick();
            const state = store.get();
            try grt.std.testing.expectEqual(@as(u32, 51), state.source_id);
            try grt.std.testing.expectEqual(modem_event.SimState.ready, state.sim);
            try grt.std.testing.expectEqual(modem_event.RegistrationState.home, state.registration);
            try grt.std.testing.expectEqual(modem_event.PacketState.connected, state.packet);
            try grt.std.testing.expectEqual(@as(?i16, -73), state.signal.?.rssi_dbm);
            try grt.std.testing.expectEqual(modem_event.Rat.lte, state.signal.?.rat);
            try grt.std.testing.expectEqualStrings("internet", state.apn());
            try grt.std.testing.expectEqual(@as(?u8, 3), if (state.call) |call| call.call_id else null);
            try grt.std.testing.expectEqual(@as(?modem_event.CallEndReason, .remote_hangup), if (state.call) |call| call.end_reason else null);
            try grt.std.testing.expectEqualStrings("10086", state.call.?.number());
            try grt.std.testing.expectEqual(@as(?u16, 9), if (state.sms) |sms| sms.index else null);
            try grt.std.testing.expectEqualStrings("10010", state.sms.?.sender());
            try grt.std.testing.expectEqualStrings("hi", state.sms.?.text());
            try grt.std.testing.expectEqual(modem_event.GnssState.fixed, state.gnss_state);
            try grt.std.testing.expectEqual(modem_event.GnssFixQuality.three_d, state.gnss_fix.?.quality);
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

            TestCase.reduceTracksModemState() catch |err| {
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
