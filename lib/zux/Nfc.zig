const Context = @import("event/Context.zig");
const event = @import("event.zig");

const EventReceiver = event.EventReceiver;
const Nfc = @This();

pub const max_uid_len: usize = 10;
pub const max_payload_len: usize = 256;
pub const max_buf_len: usize = max_uid_len + max_payload_len;

ptr: *anyopaque,
vtable: *const VTable,

pub const CardType = enum {
    unknown,
    ntag,
    ndef,
};

pub const FoundEvent = struct {
    pub const kind = .nfc_found;

    source_id: u32,
    uid_end: u16,
    buf: [max_uid_len]u8,
    card_type: CardType,
    ctx: Context.Type = null,

    pub fn uid(self: *const @This()) []const u8 {
        return self.buf[0..self.uid_end];
    }
};

pub const ReadEvent = struct {
    pub const kind = .nfc_read;

    source_id: u32,
    uid_end: u16,
    payload_end: u16,
    buf: [max_buf_len]u8,
    card_type: CardType,
    ctx: Context.Type = null,

    pub fn uid(self: *const @This()) []const u8 {
        return self.buf[0..self.uid_end];
    }

    pub fn payload(self: *const @This()) []const u8 {
        return self.buf[self.uid_end..self.payload_end];
    }
};

pub const Update = struct {
    source_id: u32,
    uid: []const u8,
    payload: ?[]const u8 = null,
    card_type: CardType,
    ctx: Context.Type = null,
};

pub const CallbackFn = *const fn (ctx: *const anyopaque, update: Update) void;

pub const VTable = struct {
    setEventCallback: *const fn (ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void,
    clearEventCallback: *const fn (ptr: *anyopaque) void,
};

pub fn makeEvent(update: Update) !event.Event {
    if (update.uid.len > max_uid_len) return error.InvalidUidLength;
    const payload = update.payload orelse {
        var uid_buf = [_]u8{0} ** max_uid_len;
        @memcpy(uid_buf[0..update.uid.len], update.uid);
        return .{
            .nfc_found = .{
                .source_id = update.source_id,
                .uid_end = @intCast(update.uid.len),
                .buf = uid_buf,
                .card_type = update.card_type,
                .ctx = update.ctx,
            },
        };
    };

    if (payload.len > max_payload_len) return error.InvalidPayloadLength;

    var buf = [_]u8{0} ** max_buf_len;
    @memcpy(buf[0..update.uid.len], update.uid);
    @memcpy(buf[update.uid.len .. update.uid.len + payload.len], payload);

    return .{
        .nfc_read = .{
            .source_id = update.source_id,
            .uid_end = @intCast(update.uid.len),
            .payload_end = @intCast(update.uid.len + payload.len),
            .buf = buf,
            .card_type = update.card_type,
            .ctx = update.ctx,
        },
    };
}

pub fn setEventReceiver(self: Nfc, receiver: *const EventReceiver) void {
    self.vtable.setEventCallback(self.ptr, @ptrCast(receiver), eventReceiverEmitUpdate);
}

pub fn clearEventReceiver(self: Nfc) void {
    self.vtable.clearEventCallback(self.ptr);
}

pub fn init(comptime T: type, impl: *T) Nfc {
    comptime {
        _ = @as(*const fn (*T, *const anyopaque, CallbackFn) void, &T.setEventCallback);
        _ = @as(*const fn (*T) void, &T.clearEventCallback);
    }

    const gen = struct {
        fn setEventCallbackFn(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.setEventCallback(ctx, emit_fn);
        }

        fn clearEventCallbackFn(ptr: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.clearEventCallback();
        }

        const vtable = VTable{
            .setEventCallback = setEventCallbackFn,
            .clearEventCallback = clearEventCallbackFn,
        };
    };

    return .{
        .ptr = @ptrCast(impl),
        .vtable = &gen.vtable,
    };
}

fn eventReceiverEmitUpdate(ctx: *const anyopaque, update: Update) void {
    const receiver: *const EventReceiver = @ptrCast(@alignCast(ctx));
    const value = makeEvent(update) catch @panic("zux.Nfc received invalid adapter event");
    receiver.emit(value);
}

test "zux/Nfc/unit_tests/set_and_emit_found_and_read_through_event_receiver" {
    const std = @import("std");

    const Sink = struct {
        called: bool = false,
        last_source_id: u32 = 0,
        last_card_type: ?CardType = null,
        last_uid_len: usize = 0,
        last_payload_len: usize = 0,
        found_count: usize = 0,
        read_count: usize = 0,

        fn emitFn(ctx: *anyopaque, value: event.Event) void {
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
        emit_fn: ?CallbackFn = null,

        pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: CallbackFn) void {
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
    const nfc = Nfc.init(Impl, &impl);
    nfc.setEventReceiver(&receiver);
    try impl.emit();

    try std.testing.expect(sink.called);
    try std.testing.expectEqual(@as(u32, 21), sink.last_source_id);
    try std.testing.expectEqual(@as(?CardType, .ndef), sink.last_card_type);
    try std.testing.expectEqual(@as(usize, 4), sink.last_uid_len);
    try std.testing.expectEqual(@as(usize, 4), sink.last_payload_len);
    try std.testing.expectEqual(@as(usize, 1), sink.found_count);
    try std.testing.expectEqual(@as(usize, 1), sink.read_count);

    nfc.clearEventReceiver();
    try std.testing.expect(impl.receiver_ctx == null);
    try std.testing.expect(impl.emit_fn == null);
}
