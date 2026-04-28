const bt = @import("bt");
const bt_event = @import("event.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const zux_event = @import("../../event.zig");
const glib = @import("glib");

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

pub fn attach(self: *const EventHook, host: bt.Host) void {
    host.setEventCallback(@ptrCast(self), emitFn);
}

pub fn detach(_: *const EventHook, host: bt.Host) void {
    host.clearEventCallback();
}

pub fn emitFn(ctx: *const anyopaque, source_id: u32, host_event: bt.Host.Event) void {
    const self: *const EventHook = @ptrCast(@alignCast(ctx));
    const out = self.out orelse return;
    const value = bt_event.make(zux_event.Event, source_id, host_event) catch @panic("zux.component.bt.EventHook received unsupported bt.Host event");

    out.emit(.{
        .origin = .source,
        .timestamp = 0,
        .body = value,
    }) catch @panic("zux.component.bt.EventHook failed to forward event");
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn emitFnForwardsThroughEmitter() !void {
            const Sink = struct {
                called: bool = false,
                last_source_id: u32 = 0,

                pub fn emit(self: *@This(), message: @import("../../pipeline/Message.zig")) !void {
                    self.called = true;
                    switch (message.body) {
                        .ble_periph_advertising_started => |value| {
                            self.last_source_id = value.source_id;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var sink = Sink{};
            var hook = EventHook.init();
            hook.bindOutput(Emitter.init(&sink));

            EventHook.emitFn(@ptrCast(&hook), 41, .{
                .peripheral = .{
                    .advertising_started = {},
                },
            });

            try grt.std.testing.expect(sink.called);
            try grt.std.testing.expectEqual(@as(u32, 41), sink.last_source_id);
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

            TestCase.emitFnForwardsThroughEmitter() catch |err| {
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
