const drivers = @import("drivers");
const zux_event = @import("../event.zig");
const glib = @import("glib");

pub const event = @import("nfc/event.zig");
pub const State = @import("nfc/State.zig");
pub const EventHook = @import("nfc/EventHook.zig");
pub const Reducer = @import("nfc/Reducer.zig");

const EventReceiver = zux_event.EventReceiver;
const root = @This();

reader: drivers.nfc.Reader,

pub const max_uid_len = event.max_uid_len;
pub const max_payload_len = event.max_payload_len;
pub const max_buf_len = event.max_buf_len;
pub const CardType = event.CardType;
pub const FoundEvent = event.Found;
pub const ReadEvent = event.Read;

pub fn init(reader: drivers.nfc.Reader) root {
    return .{
        .reader = reader,
    };
}

pub fn setEventReceiver(self: root, receiver: *const EventReceiver) void {
    self.reader.setEventCallback(@ptrCast(receiver), eventReceiverEmitUpdate);
}

pub fn clearEventReceiver(self: root) void {
    self.reader.clearEventCallback();
}

fn eventReceiverEmitUpdate(ctx: *const anyopaque, update: drivers.nfc.Update) void {
    const receiver: *const EventReceiver = @ptrCast(@alignCast(ctx));
    const value = event.make(zux_event.Event, update, null) catch @panic("zux.component.nfc received invalid adapter event");
    receiver.emit(value);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn setAndEmitFoundAndReadThroughEventReceiver() !void {
            const Sink = struct {
                called: bool = false,
                last_source_id: u32 = 0,
                last_card_type: ?CardType = null,
                last_uid_len: usize = 0,
                last_payload_len: usize = 0,
                found_count: usize = 0,
                read_count: usize = 0,

                fn emitFn(ctx: *anyopaque, value: zux_event.Event) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    self.called = true;
                    switch (value) {
                        .nfc_found => |found| {
                            self.found_count += 1;
                            self.last_source_id = found.source_id;
                            self.last_card_type = found.card_type;
                            self.last_uid_len = found.uid().len;
                            self.last_payload_len = 0;
                        },
                        .nfc_read => |read_event| {
                            self.read_count += 1;
                            self.last_source_id = read_event.source_id;
                            self.last_card_type = read_event.card_type;
                            self.last_uid_len = read_event.uid().len;
                            self.last_payload_len = read_event.payload().len;
                        },
                        else => {},
                    }
                }
            };

            const Impl = struct {
                receiver_ctx: ?*const anyopaque = null,
                emit_fn: ?drivers.nfc.CallbackFn = null,

                pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: drivers.nfc.CallbackFn) void {
                    self.receiver_ctx = ctx;
                    self.emit_fn = emit_fn;
                }

                pub fn clearEventCallback(self: *@This()) void {
                    self.receiver_ctx = null;
                    self.emit_fn = null;
                }

                pub fn emit(self: *@This()) !void {
                    var buf = [_]u8{0} ** max_buf_len;
                    buf[0] = 0x04;
                    buf[1] = 0xA1;
                    buf[2] = 0xB2;
                    buf[3] = 0xC3;
                    buf[4] = 0x03;
                    buf[5] = 0x02;
                    buf[6] = 0xD1;
                    buf[7] = 0x01;

                    const receiver_ctx = self.receiver_ctx orelse return error.MissingReceiver;
                    const emit_fn = self.emit_fn orelse return error.MissingHook;
                    emit_fn(receiver_ctx, .{
                        .source_id = 21,
                        .uid = buf[0..4],
                        .payload = null,
                        .card_type = .ndef,
                    });
                    emit_fn(receiver_ctx, .{
                        .source_id = 21,
                        .uid = buf[0..4],
                        .payload = buf[4..8],
                        .card_type = .ndef,
                    });
                }
            };

            var sink = Sink{};
            const receiver = EventReceiver.init(@ptrCast(&sink), Sink.emitFn);

            var impl = Impl{};
            const reader = drivers.nfc.Reader.init(&impl);
            const nfc = root.init(reader);
            nfc.setEventReceiver(&receiver);
            try impl.emit();

            try grt.std.testing.expect(sink.called);
            try grt.std.testing.expectEqual(@as(u32, 21), sink.last_source_id);
            try grt.std.testing.expectEqual(@as(?CardType, .ndef), sink.last_card_type);
            try grt.std.testing.expectEqual(@as(usize, 4), sink.last_uid_len);
            try grt.std.testing.expectEqual(@as(usize, 4), sink.last_payload_len);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.found_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.read_count);

            nfc.clearEventReceiver();
            try grt.std.testing.expect(impl.receiver_ctx == null);
            try grt.std.testing.expect(impl.emit_fn == null);
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

            TestCase.setAndEmitFoundAndReadThroughEventReceiver() catch |err| {
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
