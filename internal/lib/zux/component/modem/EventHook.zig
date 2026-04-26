const modem_api = @import("drivers");
const modem_event = @import("event.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const zux_event = @import("../../event.zig");
const glib = @import("glib");

const EventHook = @This();

out: ?Emitter = null,

pub fn init() EventHook {
    return .{};
}

pub fn bindOutput(self: *EventHook, out: Emitter) void {
    self.out = out;
}

pub fn clearOutput(self: *EventHook) void {
    self.out = null;
}

pub fn attach(self: *const EventHook, adapter: modem_api.Modem) void {
    adapter.setEventCallback(@ptrCast(self), emitFn);
}

pub fn detach(_: *const EventHook, adapter: modem_api.Modem) void {
    adapter.clearEventCallback();
}

pub fn emitFn(ctx: *const anyopaque, source_id: u32, adapter_event: modem_api.Modem.Event) void {
    const self: *const EventHook = @ptrCast(@alignCast(ctx));
    const out = self.out orelse return;
    const value = modem_event.make(zux_event.Event, source_id, adapter_event) catch return;

    out.emit(.{
        .origin = .source,
        .timestamp_ns = 0,
        .body = value,
    }) catch @panic("zux.component.modem.EventHook failed to forward event");
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn emitFnForwardsSignalThroughEmitter(testing: anytype) !void {
            const Sink = struct {
                called: bool = false,
                last_source_id: u32 = 0,
                last_rssi_dbm: i16 = 0,

                pub fn emit(self: *@This(), message: @import("../../pipeline/Message.zig")) !void {
                    self.called = true;
                    switch (message.body) {
                        .modem_network_signal_changed => |value| {
                            self.last_source_id = value.source_id;
                            self.last_rssi_dbm = value.signal.rssi_dbm;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var sink = Sink{};
            var hook = EventHook.init();
            hook.bindOutput(Emitter.init(&sink));

            EventHook.emitFn(@ptrCast(&hook), 51, .{
                .network = .{
                    .signal_changed = .{
                        .rssi_dbm = -73,
                        .ber = 2,
                        .rat = .lte,
                    },
                },
            });

            try testing.expect(sink.called);
            try testing.expectEqual(@as(u32, 51), sink.last_source_id);
            try testing.expectEqual(@as(i16, -73), sink.last_rssi_dbm);
        }

        fn emitFnForwardsApnThroughEmitter(testing: anytype) !void {
            const Sink = struct {
                called: bool = false,
                last_source_id: u32 = 0,
                last_apn_len: usize = 0,

                pub fn emit(self: *@This(), message: @import("../../pipeline/Message.zig")) !void {
                    self.called = true;
                    switch (message.body) {
                        .modem_data_apn_changed => |value| {
                            self.last_source_id = value.source_id;
                            self.last_apn_len = value.apn().len;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var sink = Sink{};
            var hook = EventHook.init();
            hook.bindOutput(Emitter.init(&sink));

            EventHook.emitFn(@ptrCast(&hook), 52, .{
                .data = .{
                    .apn_changed = "internet",
                },
            });

            try testing.expect(sink.called);
            try testing.expectEqual(@as(u32, 52), sink.last_source_id);
            try testing.expectEqual(@as(usize, 8), sink.last_apn_len);
        }

        fn emitFnForwardsIncomingCallThroughEmitter(testing: anytype) !void {
            const Sink = struct {
                called: bool = false,
                last_source_id: u32 = 0,
                last_call_id: u8 = 0,
                last_number_len: usize = 0,

                pub fn emit(self: *@This(), message: @import("../../pipeline/Message.zig")) !void {
                    self.called = true;
                    switch (message.body) {
                        .modem_call_incoming => |value| {
                            self.last_source_id = value.source_id;
                            self.last_call_id = value.call_id;
                            self.last_number_len = value.number().len;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var sink = Sink{};
            var hook = EventHook.init();
            hook.bindOutput(Emitter.init(&sink));

            EventHook.emitFn(@ptrCast(&hook), 53, .{
                .call = .{
                    .incoming = .{
                        .call_id = 7,
                        .direction = .incoming,
                        .number = "+8613800138000",
                    },
                },
            });

            try testing.expect(sink.called);
            try testing.expectEqual(@as(u32, 53), sink.last_source_id);
            try testing.expectEqual(@as(u8, 7), sink.last_call_id);
            try testing.expectEqual(@as(usize, 14), sink.last_number_len);
        }

        fn emitFnDropsInvalidApn(testing: anytype) !void {
            const Sink = struct {
                called: bool = false,

                pub fn emit(self: *@This(), _: @import("../../pipeline/Message.zig")) !void {
                    self.called = true;
                }
            };

            var sink = Sink{};
            var hook = EventHook.init();
            hook.bindOutput(Emitter.init(&sink));

            var apn_buf = [_]u8{'a'} ** (modem_event.max_apn_len + 1);
            EventHook.emitFn(@ptrCast(&hook), 54, .{
                .data = .{
                    .apn_changed = apn_buf[0..],
                },
            });

            try testing.expect(!sink.called);
        }

        fn emitFnDropsInvalidIncomingCall(testing: anytype) !void {
            const Sink = struct {
                called: bool = false,

                pub fn emit(self: *@This(), _: @import("../../pipeline/Message.zig")) !void {
                    self.called = true;
                }
            };

            var sink = Sink{};
            var hook = EventHook.init();
            hook.bindOutput(Emitter.init(&sink));

            var number_buf = [_]u8{'1'} ** (modem_event.max_phone_number_len + 1);
            EventHook.emitFn(@ptrCast(&hook), 55, .{
                .call = .{
                    .incoming = .{
                        .call_id = 8,
                        .direction = .incoming,
                        .number = number_buf[0..],
                    },
                },
            });

            try testing.expect(!sink.called);
        }

        fn emitFnDropsInvalidSmsText(testing: anytype) !void {
            const Sink = struct {
                called: bool = false,

                pub fn emit(self: *@This(), _: @import("../../pipeline/Message.zig")) !void {
                    self.called = true;
                }
            };

            var sink = Sink{};
            var hook = EventHook.init();
            hook.bindOutput(Emitter.init(&sink));

            var text_buf = [_]u8{'x'} ** (modem_event.max_sms_text_len + 1);
            EventHook.emitFn(@ptrCast(&hook), 56, .{
                .sms = .{
                    .received = .{
                        .sender = "10010",
                        .text = text_buf[0..],
                    },
                },
            });

            try testing.expect(!sink.called);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            TestCase.emitFnForwardsSignalThroughEmitter(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.emitFnForwardsApnThroughEmitter(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.emitFnForwardsIncomingCallThroughEmitter(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.emitFnDropsInvalidApn(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.emitFnDropsInvalidIncomingCall(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.emitFnDropsInvalidSmsText(testing) catch |err| {
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
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
