const drivers = @import("drivers");
const glib = @import("glib");

const Emitter = @import("../../pipeline/Emitter.zig");

const EventHook = @This();

source_id: u32,
out: ?Emitter = null,

pub fn init(source_id: u32) EventHook {
    return .{
        .source_id = source_id,
    };
}

pub fn bindOutput(self: *EventHook, out: Emitter) void {
    self.out = out;
}

pub fn clearOutput(self: *EventHook) void {
    self.out = null;
}

pub fn attach(self: *const EventHook, gpio: drivers.Gpio) drivers.Gpio.Error!void {
    try gpio.configureInterrupt(.both);
    gpio.setEventCallback(@ptrCast(self), emitFn);
}

pub fn detach(_: *const EventHook, gpio: drivers.Gpio) void {
    gpio.clearEventCallback();
}

pub fn emitFn(ctx: *const anyopaque, event: drivers.Gpio.Event) void {
    const self: *const EventHook = @ptrCast(@alignCast(ctx));
    const out = self.out orelse return;

    out.emit(.{
        .origin = .source,
        .timestamp = 0,
        .body = .{
            .raw_gpio_changed = .{
                .source_id = self.source_id,
                .edge = event.edge,
                .level = event.level,
            },
        },
    }) catch @panic("zux.component.gpio.EventHook failed to forward event");
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn emitFnAddsSourceIdAndForwardsEvent() !void {
            const Sink = struct {
                called: bool = false,
                source_id: u32 = 0,
                edge: drivers.Gpio.Edge = .rising,
                level: drivers.Gpio.Level = .low,

                pub fn emit(self: *@This(), message: @import("../../pipeline/Message.zig")) !void {
                    switch (message.body) {
                        .raw_gpio_changed => |value| {
                            self.called = true;
                            self.source_id = value.source_id;
                            self.edge = value.edge;
                            self.level = value.level;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var sink = Sink{};
            var hook = EventHook.init(72);
            hook.bindOutput(Emitter.init(&sink));

            EventHook.emitFn(@ptrCast(&hook), .{
                .edge = .falling,
                .level = .low,
            });

            try grt.std.testing.expect(sink.called);
            try grt.std.testing.expectEqual(@as(u32, 72), sink.source_id);
            try grt.std.testing.expectEqual(drivers.Gpio.Edge.falling, sink.edge);
            try grt.std.testing.expectEqual(drivers.Gpio.Level.low, sink.level);
        }

        fn attachAndDetachUseDriverCallback() !void {
            const Pin = struct {
                configured_edge: ?drivers.Gpio.Edge = null,
                callback_ctx: ?*const anyopaque = null,
                callback_fn: ?drivers.Gpio.CallbackFn = null,
                clear_count: usize = 0,

                pub fn read(_: *@This()) drivers.Gpio.Error!drivers.Gpio.Level {
                    return .low;
                }

                pub fn write(_: *@This(), _: drivers.Gpio.Level) drivers.Gpio.Error!void {}

                pub fn setDirection(_: *@This(), _: drivers.Gpio.Direction) drivers.Gpio.Error!void {}

                pub fn configureInterrupt(self: *@This(), edge: drivers.Gpio.Edge) drivers.Gpio.Error!void {
                    self.configured_edge = edge;
                }

                pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: drivers.Gpio.CallbackFn) void {
                    self.callback_ctx = ctx;
                    self.callback_fn = emit_fn;
                }

                pub fn clearEventCallback(self: *@This()) void {
                    self.callback_ctx = null;
                    self.callback_fn = null;
                    self.clear_count += 1;
                }
            };

            var pin = Pin{};
            const gpio = drivers.Gpio.init(&pin);
            const hook = EventHook.init(4);

            try hook.attach(gpio);
            try grt.std.testing.expectEqual(@as(?drivers.Gpio.Edge, .both), pin.configured_edge);
            try grt.std.testing.expect(pin.callback_ctx != null);
            try grt.std.testing.expect(pin.callback_fn != null);

            hook.detach(gpio);
            try grt.std.testing.expect(pin.callback_ctx == null);
            try grt.std.testing.expect(pin.callback_fn == null);
            try grt.std.testing.expectEqual(@as(usize, 1), pin.clear_count);
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

            inline for (.{
                TestCase.emitFnAddsSourceIdAndForwardsEvent,
                TestCase.attachAndDetachUseDriverCallback,
            }) |case| {
                case() catch |err| {
                    t.logFatal(@errorName(err));
                    return false;
                };
            }
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
