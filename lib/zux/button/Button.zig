const Context = @import("../event/Context.zig");
const event = @import("../event.zig");

const Button = @This();

ptr: *anyopaque,
source_id: u32,
ctx: Context.Type = null,
vtable: *const VTable,

pub const Event = struct {
    pub const kind = .raw_single_button;

    source_id: u32,
    pressed: bool,
    ctx: Context.Type = null,
};

pub const VTable = struct {
    isPressed: *const fn (ptr: *anyopaque) anyerror!bool,
};

pub fn poll(self: Button) !event.Event {
    const pressed = try self.vtable.isPressed(self.ptr);
    const raw_event: Event = .{
        .source_id = self.source_id,
        .pressed = pressed,
        .ctx = self.ctx,
    };
    return .{
        .raw_single_button = .{
            .source_id = raw_event.source_id,
            .pressed = raw_event.pressed,
            .ctx = raw_event.ctx,
        },
    };
}

pub fn init(comptime T: type, impl: *T, source_id: u32) Button {
    comptime {
        _ = @as(*const fn (*T) anyerror!bool, &T.isPressed);
    }

    const gen = struct {
        fn isPressedFn(ptr: *anyopaque) anyerror!bool {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.isPressed();
        }

        const vtable = VTable{
            .isPressed = isPressedFn,
        };
    };

    return .{
        .ptr = @ptrCast(impl),
        .source_id = source_id,
        .ctx = null,
        .vtable = &gen.vtable,
    };
}

test "zux/button/Button/unit_tests/init_and_poll" {
    const std = @import("std");

    const Impl = struct {
        called: bool = false,

        pub fn isPressed(self: *@This()) !bool {
            self.called = true;
            return true;
        }
    };

    var impl = Impl{};
    const button = Button.init(Impl, &impl, 1);
    const polled = try button.poll();
    switch (polled) {
        .raw_single_button => |single| {
            try std.testing.expectEqual(@as(u32, 1), single.source_id);
            try std.testing.expect(single.pressed);
            try std.testing.expect(single.ctx == null);
        },
        else => try std.testing.expect(false),
    }
    try std.testing.expect(impl.called);
}
