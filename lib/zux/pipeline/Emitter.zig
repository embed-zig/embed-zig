const Message = @import("Message.zig");

const Emitter = @This();

ctx: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    emit: *const fn (ctx: *anyopaque, message: Message) anyerror!void,
};

pub fn emit(self: Emitter, message: Message) !void {
    return self.vtable.emit(self.ctx, message);
}

pub fn init(pointer: anytype) Emitter {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Emitter.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn emitFn(ctx: *anyopaque, message: Message) anyerror!void {
            const self: *Impl = @ptrCast(@alignCast(ctx));
            try self.emit(message);
        }

        const vtable = VTable{
            .emit = emitFn,
        };
    };

    return .{
        .ctx = pointer,
        .vtable = &gen.vtable,
    };
}

test "zux/pipeline/Emitter/unit_tests/init_and_emit" {
    const std = @import("std");

    const Impl = struct {
        called: bool = false,
        last_timestamp_ns: i128 = 0,

        pub fn emit(self: *@This(), message: Message) !void {
            self.called = true;
            self.last_timestamp_ns = message.timestamp_ns;
        }
    };

    var impl = Impl{};
    const emitter = Emitter.init(&impl);
    try emitter.emit(.{
        .origin = .source,
        .timestamp_ns = 9,
        .body = .{
            .raw_single_button = .{
                .source_id = 1,
                .pressed = true,
            },
        },
    });

    try std.testing.expect(impl.called);
    try std.testing.expectEqual(@as(i128, 9), impl.last_timestamp_ns);
}
