const glib = @import("glib");

const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const State = @import("state.zig");
const touch_event = @import("event.zig");

pub fn reduce(store: anytype, message: Message, emit: Emitter) !usize {
    _ = emit;

    switch (message.body) {
        .raw_touch => |raw| {
            const current = store.get();
            const primary = primaryPoint(raw);
            store.set(.{
                .source_id = raw.source_id,
                .pressed = raw.pressed,
                .point_count = raw.point_count,
                .primary = primary,
                .last_primary = primary orelse current.last_primary,
            });
            return 0;
        },
        else => return 0,
    }
}

fn primaryPoint(raw: touch_event.Raw) ?State.Point {
    if (!raw.pressed or raw.point_count == 0) return null;
    return .{
        .id = raw.id,
        .x = raw.x,
        .y = raw.y,
        .pressure = raw.pressure,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        const Store = struct {
            state: State = .{},

            pub fn get(self: *@This()) State {
                return self.state;
            }

            pub fn set(self: *@This(), state: State) void {
                self.state = state;
            }
        };

        const Sink = struct {
            pub fn emit(_: *@This(), _: Message) !void {}
        };

        fn pressMoveAndReleaseUpdatesPrimaryAndLastPrimary() !void {
            var store = Store{};
            var sink = Sink{};
            const emit = Emitter.init(&sink);

            _ = try reduce(&store, .{
                .body = .{
                    .raw_touch = .{
                        .source_id = 101,
                        .pressed = true,
                        .point_count = 1,
                        .id = 2,
                        .x = 10,
                        .y = 20,
                        .pressure = 30,
                    },
                },
            }, emit);

            try grt.std.testing.expect(store.state.pressed);
            try grt.std.testing.expectEqual(@as(usize, 1), store.state.point_count);
            try grt.std.testing.expectEqual(@as(u16, 10), store.state.primary.?.x);
            try grt.std.testing.expectEqual(@as(u16, 20), store.state.last_primary.?.y);

            _ = try reduce(&store, .{
                .body = .{
                    .raw_touch = .{
                        .source_id = 101,
                        .pressed = true,
                        .point_count = 1,
                        .id = 2,
                        .x = 30,
                        .y = 40,
                    },
                },
            }, emit);

            try grt.std.testing.expectEqual(@as(u16, 30), store.state.primary.?.x);
            try grt.std.testing.expectEqual(@as(u16, 40), store.state.last_primary.?.y);

            _ = try reduce(&store, .{
                .body = .{
                    .raw_touch = .{
                        .source_id = 101,
                        .pressed = false,
                        .point_count = 0,
                    },
                },
            }, emit);

            try grt.std.testing.expect(!store.state.pressed);
            try grt.std.testing.expect(store.state.primary == null);
            try grt.std.testing.expectEqual(@as(u16, 30), store.state.last_primary.?.x);
            try grt.std.testing.expectEqual(@as(u16, 40), store.state.last_primary.?.y);
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

            TestCase.pressMoveAndReleaseUpdatesPrimaryAndLastPrimary() catch |err| {
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
