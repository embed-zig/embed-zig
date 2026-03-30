const Subscriber = @This();

ctx: *anyopaque,
vtable: *const VTable,

pub const Notification = struct {
    label: []const u8,
    tick_count: u64,
};

pub const VTable = struct {
    notify: *const fn (ctx: *anyopaque, notification: Notification) void,
};

pub fn notify(self: Subscriber, notification: Notification) void {
    self.vtable.notify(self.ctx, notification);
}

pub fn init(pointer: anytype) Subscriber {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Subscriber.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn notifyFn(ctx: *anyopaque, notification: Notification) void {
            const self: *Impl = @ptrCast(@alignCast(ctx));
            self.notify(notification);
        }

        const vtable = VTable{
            .notify = notifyFn,
        };
    };

    return .{
        .ctx = pointer,
        .vtable = &gen.vtable,
    };
}

test "zux/unit_tests/store/Subscriber/init_and_notify" {
    const std = @import("std");

    const Impl = struct {
        called: bool = false,
        label: []const u8 = "",
        tick_count: u64 = 0,

        pub fn notify(self: *@This(), notification: Notification) void {
            self.called = true;
            self.label = notification.label;
            self.tick_count = notification.tick_count;
        }
    };

    var impl = Impl{};
    const subscriber = Subscriber.init(&impl);
    subscriber.notify(.{ .label = "zux/test", .tick_count = 7 });

    try std.testing.expect(impl.called);
    try std.testing.expectEqualStrings("zux/test", impl.label);
    try std.testing.expectEqual(@as(u64, 7), impl.tick_count);
}
