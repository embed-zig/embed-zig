const event = @import("../event.zig");
const glib = @import("glib");

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

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn emitDispatchesThroughFunctionPointer() !void {
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

            try grt.std.testing.expect(impl.called);
            try grt.std.testing.expectEqual(@as(u32, 7), impl.source_id);
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

            TestCase.emitDispatchesThroughFunctionPointer() catch |err| {
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
