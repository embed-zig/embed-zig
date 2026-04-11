const modem_api = @import("modem");
const zux_event = @import("../event.zig");
const testing_api = @import("testing");

pub const event = @import("modem/event.zig");
pub const state = @import("modem/state.zig");
pub const EventHook = @import("modem/EventHook.zig");
pub const Reducer = @import("modem/Reducer.zig");

const EventReceiver = zux_event.EventReceiver;
const root = @This();

adapter: modem_api.Modem,

pub const max_apn_len = event.max_apn_len;
pub const Rat = event.Rat;
pub const SimState = event.SimState;
pub const RegistrationState = event.RegistrationState;
pub const PacketState = event.PacketState;
pub const SignalInfo = event.SignalInfo;
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
    const value = event.make(zux_event.Event, source_id, adapter_event) catch @panic("zux.component.modem received invalid modem event");
    receiver.emit(value);
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn setAndEmitReportsThroughEventReceiver(testing: anytype) !void {
            const Sink = struct {
                sim_count: usize = 0,
                registration_count: usize = 0,
                packet_count: usize = 0,
                signal_count: usize = 0,
                apn_count: usize = 0,
                last_source_id: u32 = 0,
                last_rssi_dbm: i16 = 0,
                last_apn_len: usize = 0,

                fn emitFn(ctx: *anyopaque, value: zux_event.Event) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    switch (value) {
                        .modem_sim_state_changed => |report| {
                            self.sim_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .modem_registration_changed => |report| {
                            self.registration_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .modem_packet_state_changed => |report| {
                            self.packet_count += 1;
                            self.last_source_id = report.source_id;
                        },
                        .modem_signal_changed => |report| {
                            self.signal_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_rssi_dbm = report.signal.rssi_dbm;
                        },
                        .modem_apn_changed => |report| {
                            self.apn_count += 1;
                            self.last_source_id = report.source_id;
                            self.last_apn_len = report.apn().len;
                        },
                        else => {},
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

            try testing.expectEqual(@as(usize, 1), sink.sim_count);
            try testing.expectEqual(@as(usize, 1), sink.registration_count);
            try testing.expectEqual(@as(usize, 1), sink.packet_count);
            try testing.expectEqual(@as(usize, 1), sink.signal_count);
            try testing.expectEqual(@as(usize, 1), sink.apn_count);
            try testing.expectEqual(@as(u32, 51), sink.last_source_id);
            try testing.expectEqual(@as(i16, -73), sink.last_rssi_dbm);
            try testing.expectEqual(@as(usize, 8), sink.last_apn_len);

            component.clearEventReceiver();
            try testing.expect(adapter_impl.receiver_ctx == null);
            try testing.expect(adapter_impl.emit_fn == null);
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

        emit_fn(receiver_ctx, 51, .{ .sim_state_changed = .ready });
        emit_fn(receiver_ctx, 51, .{ .registration_changed = .home });
        emit_fn(receiver_ctx, 51, .{ .packet_state_changed = .connected });
        emit_fn(receiver_ctx, 51, .{
            .signal_changed = .{
                .rssi_dbm = -73,
                .ber = 2,
                .rat = .lte,
            },
        });
        emit_fn(receiver_ctx, 51, .{ .apn_changed = "internet" });
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
