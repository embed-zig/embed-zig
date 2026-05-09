const drivers = @import("drivers");
const glib = @import("glib");

const Context = @import("../../event/Context.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");

const EventHook = @This();

pub const Config = struct {
    source_id: u32,
    ctx: Context.Type = null,
};

source_id: u32,
ctx: Context.Type = null,
out: ?Emitter = null,

pub fn init(config: Config) EventHook {
    return .{
        .source_id = config.source_id,
        .ctx = config.ctx,
    };
}

pub fn bindOutput(self: *EventHook, out: Emitter) void {
    self.out = out;
}

pub fn clearOutput(self: *EventHook) void {
    self.out = null;
}

pub fn attach(self: *const EventHook, touch: drivers.Touch) void {
    touch.setEventCallback(@ptrCast(self), emitFn);
}

pub fn detach(_: *const EventHook, touch: drivers.Touch) void {
    touch.clearEventCallback();
}

pub fn emitFn(ctx: *const anyopaque, event: drivers.Touch.Event) void {
    const self: *const EventHook = @ptrCast(@alignCast(ctx));
    const out = self.out orelse return;
    const raw = if (event.primary) |point| Message.Event{
        .raw_touch = .{
            .source_id = self.source_id,
            .pressed = event.pressed,
            .point_count = event.point_count,
            .id = point.id,
            .x = point.x,
            .y = point.y,
            .pressure = point.pressure,
            .ctx = self.ctx,
        },
    } else Message.Event{
        .raw_touch = .{
            .source_id = self.source_id,
            .pressed = event.pressed,
            .point_count = event.point_count,
            .ctx = self.ctx,
        },
    };

    out.emit(.{
        .origin = .source,
        .timestamp = 0,
        .body = raw,
    }) catch @panic("zux.component.touch.EventHook failed to forward event");
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn emitFnForwardsPrimaryPointThroughEmitter() !void {
            const Sink = struct {
                called: bool = false,
                last_source_id: u32 = 0,
                last_pressed: bool = false,
                last_x: u16 = 0,
                last_y: u16 = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    self.called = true;
                    switch (message.body) {
                        .raw_touch => |value| {
                            self.last_source_id = value.source_id;
                            self.last_pressed = value.pressed;
                            self.last_x = value.x;
                            self.last_y = value.y;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var sink = Sink{};
            var hook = EventHook.init(.{ .source_id = 25 });
            hook.bindOutput(Emitter.init(&sink));

            EventHook.emitFn(@ptrCast(&hook), .{
                .pressed = true,
                .point_count = 1,
                .primary = .{
                    .id = 1,
                    .x = 120,
                    .y = 80,
                    .pressure = 42,
                },
            });

            try grt.std.testing.expect(sink.called);
            try grt.std.testing.expectEqual(@as(u32, 25), sink.last_source_id);
            try grt.std.testing.expect(sink.last_pressed);
            try grt.std.testing.expectEqual(@as(u16, 120), sink.last_x);
            try grt.std.testing.expectEqual(@as(u16, 80), sink.last_y);
        }

        fn emitFnForwardsReleaseThroughEmitter() !void {
            const Sink = struct {
                called: bool = false,
                last_pressed: bool = true,
                last_point_count: usize = 99,

                pub fn emit(self: *@This(), message: Message) !void {
                    self.called = true;
                    switch (message.body) {
                        .raw_touch => |value| {
                            self.last_pressed = value.pressed;
                            self.last_point_count = value.point_count;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var sink = Sink{};
            var hook = EventHook.init(.{ .source_id = 25 });
            hook.bindOutput(Emitter.init(&sink));

            EventHook.emitFn(@ptrCast(&hook), .{
                .pressed = false,
                .point_count = 0,
                .primary = null,
            });

            try grt.std.testing.expect(sink.called);
            try grt.std.testing.expect(!sink.last_pressed);
            try grt.std.testing.expectEqual(@as(usize, 0), sink.last_point_count);
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

            TestCase.emitFnForwardsPrimaryPointThroughEmitter() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.emitFnForwardsReleaseThroughEmitter() catch |err| {
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
