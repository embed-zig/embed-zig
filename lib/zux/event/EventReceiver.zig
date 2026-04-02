const event = @import("../event.zig");

const EventReceiver = @This();

ctx: *anyopaque,
emit_fn: *const fn (ctx: *anyopaque, value: event.Event) void,

pub fn init(ctx: *anyopaque, emit_fn: *const fn (*anyopaque, event.Event) void) EventReceiver {
    return .{
        .ctx = ctx,
        .emit_fn = emit_fn,
    };
}

pub fn emit(self: EventReceiver, value: event.Event) void {
    self.emit_fn(self.ctx, value);
}

test "zux/event/EventReceiver/unit_tests/emit_dispatches_through_function_pointer" {
    const std = @import("std");

    const Impl = struct {
        called: bool = false,
        source_id: u32 = 0,

        pub fn emit(self: *@This(), value: event.Event) void {
            self.called = true;
            switch (value) {
                .raw_single_button => |button| self.source_id = button.source_id,
                else => {},
            }
        }
    };

    const ReceiverFn = struct {
        fn emitFn(ctx: *anyopaque, value: event.Event) void {
            const self: *Impl = @ptrCast(@alignCast(ctx));
            self.emit(value);
        }
    };

    var impl = Impl{};
    const receiver = EventReceiver.init(@ptrCast(&impl), ReceiverFn.emitFn);
    receiver.emit(.{
        .raw_single_button = .{
            .source_id = 7,
            .pressed = true,
        },
    });

    try std.testing.expect(impl.called);
    try std.testing.expectEqual(@as(u32, 7), impl.source_id);
}
