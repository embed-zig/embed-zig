const modem_api = @import("drivers");
const zux_event = @import("../event.zig");
const glib = @import("glib");

pub const event = @import("modem/event.zig");
pub const State = @import("modem/State.zig");
pub const EventHook = @import("modem/EventHook.zig");
pub const Reducer = @import("modem/Reducer.zig");

const EventReceiver = zux_event.EventReceiver;
const root = @This();

adapter: modem_api.Modem,

pub const max_apn_len = event.max_apn_len;
pub const max_phone_number_len = event.max_phone_number_len;
pub const max_sms_text_len = event.max_sms_text_len;
pub const Rat = event.Rat;
pub const SimState = event.SimState;
pub const RegistrationState = event.RegistrationState;
pub const PacketState = event.PacketState;
pub const SignalInfo = event.SignalInfo;
pub const CallDirection = event.CallDirection;
pub const CallState = event.CallState;
pub const CallEndReason = event.CallEndReason;
pub const CallInfo = event.CallInfo;
pub const CallStatus = event.CallStatus;
pub const CallEndInfo = event.CallEndInfo;
pub const SmsStorage = event.SmsStorage;
pub const SmsEncoding = event.SmsEncoding;
pub const SmsMessage = event.SmsMessage;
pub const GnssState = event.GnssState;
pub const GnssFixQuality = event.GnssFixQuality;
pub const GnssFix = event.GnssFix;
pub const Event = event.Event;
pub const CallbackFn = event.CallbackFn;

pub fn init(adapter: modem_api.Modem) root {
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
    const value = event.make(zux_event.Event, source_id, adapter_event) catch return;
    receiver.emit(value);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn setAndEmitReportsThroughEventReceiver() !void {
            const Sink = struct {
                sim_count: usize = 0,
                network_registration_count: usize = 0,
                data_packet_count: usize = 0,
                network_signal_count: usize = 0,
                data_apn_count: usize = 0,
                call_incoming_count: usize = 0,
                call_state_count: usize = 0,
                call_end_count: usize = 0,
                sms_count: usize = 0,
                gnss_state_count: usize = 0,
                gnss_fix_count: usize = 0,
                last_source_id: u32 = 0,
                last_rssi_dbm: i16 = 0,
                last_apn_len: usize = 0,
                last_call_id: u8 = 0,
                last_call_end_reason: CallEndReason = .unknown,
                last_sms_len: usize = 0,
                last_gnss_state: GnssState = .idle,
                last_gnss_fix_quality: GnssFixQuality = .none,

                fn emitFn(ctx: *anyopaque, value: zux_event.Event) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    switch (value) {
                        .modem_sim_state_changed => |report| {
                            self.sim_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .modem_network_registration_changed => |report| {
                            self.network_registration_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .modem_data_packet_state_changed => |report| {
                            self.data_packet_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .modem_network_signal_changed => |report| {
                            self.network_signal_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_rssi_dbm = report.signal.rssi_dbm;
                        },
                        .modem_data_apn_changed => |report| {
                            self.data_apn_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_apn_len = report.apn().len;
                        },
                        .modem_call_incoming => |report| {
                            self.call_incoming_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_call_id = report.call_id;
                        },
                        .modem_call_state_changed => |report| {
                            self.call_state_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_call_id = report.call_id;
                        },
                        .modem_call_ended => |report| {
                            self.call_end_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_call_id = report.call_id;
                            self.last_call_end_reason = report.reason;
                        },
                        .modem_sms_received => |report| {
                            self.sms_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_sms_len = report.text().len;
                        },
                        .modem_gnss_state_changed => |report| {
                            self.gnss_state_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_gnss_state = report.state;
                        },
                        .modem_gnss_fix_changed => |report| {
                            self.gnss_fix_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_gnss_fix_quality = report.fix.quality;
                        },
                        else => unreachable,
                    }
                }
            };

            var sink = Sink{};
            const receiver = EventReceiver.init(@ptrCast(&sink), Sink.emitFn);

            var adapter_impl = TestCaseModem{};
            const adapter = modem_api.Modem{
                .ptr = @ptrCast(&adapter_impl),
                .vtable = &adapter_vtable,
            };
            var component = root.init(adapter);
            component.setEventReceiver(&receiver);
            try adapter_impl.emit();

            try grt.std.testing.expectEqual(@as(usize, 1), sink.sim_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.network_registration_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.data_packet_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.network_signal_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.data_apn_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.call_incoming_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.call_state_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.call_end_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.sms_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.gnss_state_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.gnss_fix_count);
            try grt.std.testing.expectEqual(@as(u32, 51), sink.last_source_id);
            try grt.std.testing.expectEqual(@as(i16, -73), sink.last_rssi_dbm);
            try grt.std.testing.expectEqual(@as(usize, 8), sink.last_apn_len);
            try grt.std.testing.expectEqual(@as(u8, 3), sink.last_call_id);
            try grt.std.testing.expectEqual(CallEndReason.remote_hangup, sink.last_call_end_reason);
            try grt.std.testing.expectEqual(@as(usize, 2), sink.last_sms_len);
            try grt.std.testing.expectEqual(GnssState.fixed, sink.last_gnss_state);
            try grt.std.testing.expectEqual(GnssFixQuality.three_d, sink.last_gnss_fix_quality);

            component.clearEventReceiver();
            try grt.std.testing.expect(adapter_impl.receiver_ctx == null);
            try grt.std.testing.expect(adapter_impl.emit_fn == null);
        }

        fn eventReceiverDropsInvalidApn() !void {
            const Sink = struct {
                called: bool = false,

                fn emitFn(ctx: *anyopaque, _: zux_event.Event) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    self.called = true;
                }
            };

            var sink = Sink{};
            const receiver = EventReceiver.init(@ptrCast(&sink), Sink.emitFn);

            var apn_buf = [_]u8{'a'} ** (event.max_apn_len + 1);
            eventReceiverEmitUpdate(
                @ptrCast(&receiver),
                88,
                .{
                    .data = .{
                        .apn_changed = apn_buf[0..],
                    },
                },
            );

            try grt.std.testing.expect(!sink.called);
        }

        fn eventReceiverDropsInvalidCallNumber() !void {
            const Sink = struct {
                called: bool = false,

                fn emitFn(ctx: *anyopaque, _: zux_event.Event) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    self.called = true;
                }
            };

            var sink = Sink{};
            const receiver = EventReceiver.init(@ptrCast(&sink), Sink.emitFn);

            var number_buf = [_]u8{'1'} ** (event.max_phone_number_len + 1);
            eventReceiverEmitUpdate(
                @ptrCast(&receiver),
                89,
                .{
                    .call = .{
                        .incoming = .{
                            .call_id = 1,
                            .direction = .incoming,
                            .number = number_buf[0..],
                        },
                    },
                },
            );

            try grt.std.testing.expect(!sink.called);
        }

        fn eventReceiverDropsInvalidSmsText() !void {
            const Sink = struct {
                called: bool = false,

                fn emitFn(ctx: *anyopaque, _: zux_event.Event) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    self.called = true;
                }
            };

            var sink = Sink{};
            const receiver = EventReceiver.init(@ptrCast(&sink), Sink.emitFn);

            var text_buf = [_]u8{'x'} ** (event.max_sms_text_len + 1);
            eventReceiverEmitUpdate(
                @ptrCast(&receiver),
                90,
                .{
                    .sms = .{
                        .received = .{
                            .sender = "10010",
                            .text = text_buf[0..],
                        },
                    },
                },
            );

            try grt.std.testing.expect(!sink.called);
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
            TestCase.eventReceiverDropsInvalidApn() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.eventReceiverDropsInvalidCallNumber() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.eventReceiverDropsInvalidSmsText() catch |err| {
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

const TestCaseModem = struct {
    receiver_ctx: ?*const anyopaque = null,
    emit_fn: ?CallbackFn = null,

    pub fn deinit(_: *@This()) void {}

    pub fn state(_: *@This()) modem_api.Modem.State {
        return .{
            .sim = .ready,
            .registration = .home,
            .packet = .connected,
            .signal = .{
                .rssi_dbm = -73,
                .ber = 2,
                .rat = .lte,
            },
        };
    }

    pub fn imei(_: *@This()) ?[]const u8 {
        return "860000000000001";
    }

    pub fn imsi(_: *@This()) ?[]const u8 {
        return "460001234567890";
    }

    pub fn apn(_: *@This()) ?[]const u8 {
        return "internet";
    }

    pub fn setApn(_: *@This(), _: []const u8) modem_api.Modem.SetApnError!void {}

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

        emit_fn(receiver_ctx, 51, .{
            .sim = .{
                .state_changed = .ready,
            },
        });
        emit_fn(receiver_ctx, 51, .{
            .network = .{
                .registration_changed = .home,
            },
        });
        emit_fn(receiver_ctx, 51, .{
            .data = .{
                .packet_state_changed = .connected,
            },
        });
        emit_fn(receiver_ctx, 51, .{
            .network = .{
                .signal_changed = .{
                    .rssi_dbm = -73,
                    .ber = 2,
                    .rat = .lte,
                },
            },
        });
        emit_fn(receiver_ctx, 51, .{
            .data = .{
                .apn_changed = "internet",
            },
        });
        emit_fn(receiver_ctx, 51, .{
            .call = .{
                .incoming = .{
                    .call_id = 3,
                    .direction = .incoming,
                    .number = "10086",
                },
            },
        });
        emit_fn(receiver_ctx, 51, .{
            .call = .{
                .state_changed = .{
                    .call_id = 3,
                    .direction = .incoming,
                    .state = .active,
                    .number = "10086",
                },
            },
        });
        emit_fn(receiver_ctx, 51, .{
            .call = .{
                .ended = .{
                    .call_id = 3,
                    .reason = .remote_hangup,
                },
            },
        });
        emit_fn(receiver_ctx, 51, .{
            .sms = .{
                .received = .{
                    .sender = "10010",
                    .text = "hi",
                },
            },
        });
        emit_fn(receiver_ctx, 51, .{
            .gnss = .{
                .state_changed = .fixed,
            },
        });
        emit_fn(receiver_ctx, 51, .{
            .gnss = .{
                .fix_changed = .{
                    .quality = .three_d,
                    .latitude_deg = 31.2304,
                    .longitude_deg = 121.4737,
                    .satellites_in_view = 12,
                    .satellites_used = 8,
                },
            },
        });
    }
};

const adapter_vtable = modem_api.Modem.VTable{
    .deinit = struct {
        fn call(ptr: *anyopaque) void {
            const self: *TestCaseModem = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
    }.call,
    .state = struct {
        fn call(ptr: *anyopaque) modem_api.Modem.State {
            const self: *TestCaseModem = @ptrCast(@alignCast(ptr));
            return self.state();
        }
    }.call,
    .imei = struct {
        fn call(ptr: *anyopaque) ?[]const u8 {
            const self: *TestCaseModem = @ptrCast(@alignCast(ptr));
            return self.imei();
        }
    }.call,
    .imsi = struct {
        fn call(ptr: *anyopaque) ?[]const u8 {
            const self: *TestCaseModem = @ptrCast(@alignCast(ptr));
            return self.imsi();
        }
    }.call,
    .apn = struct {
        fn call(ptr: *anyopaque) ?[]const u8 {
            const self: *TestCaseModem = @ptrCast(@alignCast(ptr));
            return self.apn();
        }
    }.call,
    .setApn = struct {
        fn call(ptr: *anyopaque, value: []const u8) modem_api.Modem.SetApnError!void {
            const self: *TestCaseModem = @ptrCast(@alignCast(ptr));
            return self.setApn(value);
        }
    }.call,
    .dataOpen = struct {
        fn call(_: *anyopaque) modem_api.Modem.DataOpenError!void {
            return error.Unsupported;
        }
    }.call,
    .dataClose = struct {
        fn call(_: *anyopaque) void {}
    }.call,
    .dataRead = struct {
        fn call(_: *anyopaque, _: []u8) modem_api.Modem.DataReadError!usize {
            return error.Unsupported;
        }
    }.call,
    .dataWrite = struct {
        fn call(_: *anyopaque, _: []const u8) modem_api.Modem.DataWriteError!usize {
            return error.Unsupported;
        }
    }.call,
    .dataState = struct {
        fn call(_: *anyopaque) modem_api.Modem.DataState {
            return .closed;
        }
    }.call,
    .setDataReadTimeout = struct {
        fn call(_: *anyopaque, _: ?u32) void {}
    }.call,
    .setDataWriteTimeout = struct {
        fn call(_: *anyopaque, _: ?u32) void {}
    }.call,
    .setEventCallback = struct {
        fn call(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
            const self: *TestCaseModem = @ptrCast(@alignCast(ptr));
            self.setEventCallback(ctx, emit_fn);
        }
    }.call,
    .clearEventCallback = struct {
        fn call(ptr: *anyopaque) void {
            const self: *TestCaseModem = @ptrCast(@alignCast(ptr));
            self.clearEventCallback();
        }
    }.call,
};
