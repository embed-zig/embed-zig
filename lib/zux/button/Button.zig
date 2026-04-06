const Context = @import("../event/Context.zig");
const event = @import("../event.zig");
const testing_api = @import("testing");

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

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn initAndPoll(testing: anytype) !void {
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
                    try testing.expectEqual(@as(u32, 1), single.source_id);
                    try testing.expect(single.pressed);
                    try testing.expect(single.ctx == null);
                },
                else => try testing.expect(false),
            }
            try testing.expect(impl.called);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            TestCase.initAndPoll(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
