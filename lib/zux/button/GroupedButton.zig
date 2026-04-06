const Context = @import("../event/Context.zig");
const event = @import("../event.zig");
const testing_api = @import("testing");

const GroupedButton = @This();

ptr: *anyopaque,
source_id: u32,
ctx: Context.Type = null,
vtable: *const VTable,

pub const Event = struct {
    pub const kind = .raw_grouped_button;

    source_id: u32,
    button_id: ?u32,
    pressed: bool,
    ctx: Context.Type = null,
};

pub const VTable = struct {
    pressedButtonId: *const fn (ptr: *anyopaque) anyerror!?u32,
};

pub fn poll(self: GroupedButton) !event.Event {
    const button_id = try self.vtable.pressedButtonId(self.ptr);
    const raw_event: Event = .{
        .source_id = self.source_id,
        .button_id = button_id,
        .pressed = button_id != null,
        .ctx = self.ctx,
    };
    return .{
        .raw_grouped_button = .{
            .source_id = raw_event.source_id,
            .button_id = raw_event.button_id,
            .pressed = raw_event.pressed,
            .ctx = raw_event.ctx,
        },
    };
}

pub fn init(comptime T: type, impl: *T, source_id: u32) GroupedButton {
    comptime {
        _ = @as(*const fn (*T) anyerror!?u32, &T.pressedButtonId);
    }

    const gen = struct {
        fn pressedButtonIdFn(ptr: *anyopaque) anyerror!?u32 {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.pressedButtonId();
        }

        const vtable = VTable{
            .pressedButtonId = pressedButtonIdFn,
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

                pub fn pressedButtonId(self: *@This()) !?u32 {
                    self.called = true;
                    return 3;
                }
            };

            var impl = Impl{};
            const button = GroupedButton.init(Impl, &impl, 7);
            const polled = try button.poll();
            switch (polled) {
                .raw_grouped_button => |group| {
                    try testing.expectEqual(@as(u32, 7), group.source_id);
                    try testing.expectEqual(@as(?u32, 3), group.button_id);
                    try testing.expect(group.pressed);
                    try testing.expect(group.ctx == null);
                },
                else => try testing.expect(false),
            }
            try testing.expect(impl.called);
        }

        fn nullButtonIdMeansNotPressed(testing: anytype) !void {
            const Impl = struct {
                pub fn pressedButtonId(_: *@This()) !?u32 {
                    return null;
                }
            };

            var impl = Impl{};
            const button = GroupedButton.init(Impl, &impl, 7);
            const polled = try button.poll();
            switch (polled) {
                .raw_grouped_button => |group| {
                    try testing.expectEqual(@as(u32, 7), group.source_id);
                    try testing.expect(group.button_id == null);
                    try testing.expect(!group.pressed);
                    try testing.expect(group.ctx == null);
                },
                else => try testing.expect(false),
            }
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
            TestCase.nullButtonIdMeansNotPressed(testing) catch |err| {
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
