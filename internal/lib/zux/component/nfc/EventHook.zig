const drivers = @import("drivers");
const nfc_event = @import("event.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const zux_event = @import("../../event.zig");
const testing_api = @import("testing");

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

pub fn attach(self: *const EventHook, reader: drivers.nfc.Reader) void {
    reader.setEventCallback(@ptrCast(self), emitFn);
}

pub fn detach(_: *const EventHook, reader: drivers.nfc.Reader) void {
    reader.clearEventCallback();
}

pub fn emitFn(ctx: *const anyopaque, update: drivers.nfc.Update) void {
    const self: *const EventHook = @ptrCast(@alignCast(ctx));
    const out = self.out orelse return;
    const value = nfc_event.make(zux_event.Event, update, null) catch @panic("zux.component.nfc.EventHook received invalid nfc update");

    out.emit(.{
        .origin = .source,
        .timestamp_ns = 0,
        .body = value,
    }) catch @panic("zux.component.nfc.EventHook failed to forward event");
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn emitFnForwardsFoundThroughEmitter(testing: anytype) !void {
            const Sink = struct {
                called: bool = false,
                last_source_id: u32 = 0,
                last_uid_len: usize = 0,

                pub fn emit(self: *@This(), message: @import("../../pipeline/Message.zig")) !void {
                    self.called = true;
                    switch (message.body) {
                        .nfc_found => |value| {
                            self.last_source_id = value.source_id;
                            self.last_uid_len = value.uid().len;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var sink = Sink{};
            var hook = EventHook.init();
            hook.bindOutput(Emitter.init(&sink));

            EventHook.emitFn(@ptrCast(&hook), .{
                .source_id = 21,
                .uid = &.{ 0x04, 0xA1, 0xB2, 0xC3 },
                .payload = null,
                .card_type = .ndef,
            });

            try testing.expect(sink.called);
            try testing.expectEqual(@as(u32, 21), sink.last_source_id);
            try testing.expectEqual(@as(usize, 4), sink.last_uid_len);
        }

        fn emitFnForwardsReadThroughEmitter(testing: anytype) !void {
            const Sink = struct {
                called: bool = false,
                last_source_id: u32 = 0,
                last_uid_len: usize = 0,
                last_payload_len: usize = 0,

                pub fn emit(self: *@This(), message: @import("../../pipeline/Message.zig")) !void {
                    self.called = true;
                    switch (message.body) {
                        .nfc_read => |value| {
                            self.last_source_id = value.source_id;
                            self.last_uid_len = value.uid().len;
                            self.last_payload_len = value.payload().len;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var sink = Sink{};
            var hook = EventHook.init();
            hook.bindOutput(Emitter.init(&sink));

            EventHook.emitFn(@ptrCast(&hook), .{
                .source_id = 22,
                .uid = &.{ 0x04, 0xA1, 0xB2, 0xC3 },
                .payload = &.{ 0x03, 0x02, 0xD1, 0x01 },
                .card_type = .ndef,
            });

            try testing.expect(sink.called);
            try testing.expectEqual(@as(u32, 22), sink.last_source_id);
            try testing.expectEqual(@as(usize, 4), sink.last_uid_len);
            try testing.expectEqual(@as(usize, 4), sink.last_payload_len);
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

            TestCase.emitFnForwardsFoundThroughEmitter(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.emitFnForwardsReadThroughEmitter(testing) catch |err| {
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
