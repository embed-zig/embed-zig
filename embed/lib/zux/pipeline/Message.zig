const event = @import("../event.zig");
const glib = @import("glib");

const Message = @This();

pub const Origin = enum {
    source,
    node,
    timer,
    manual,
};

pub const Event = event.Event;
pub const Kind = @typeInfo(Event).@"union".tag_type.?;

origin: Origin = .source,
timestamp: glib.time.instant.Time = 0,
body: Event,

pub fn kind(self: Message) Kind {
    return switch (self.body) {
        inline else => |_, active_kind| active_kind,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn tagTracksBodyVariant() !void {
            const message: Message = .{
                .origin = .source,
                .timestamp = 42,
                .body = .{
                    .button_gesture = .{
                        .source_id = 1,
                        .gesture = .{ .click = 1 },
                    },
                },
            };

            try grt.std.testing.expectEqual(Kind.button_gesture, message.kind());
            try grt.std.testing.expectEqual(Origin.source, message.origin);
            try grt.std.testing.expectEqual(@as(glib.time.instant.Time, 42), message.timestamp);
        }

        fn tickVariantUsesTickKind() !void {
            const message: Message = .{
                .origin = .timer,
                .timestamp = 99,
                .body = .{
                    .tick = .{},
                },
            };

            try grt.std.testing.expectEqual(Kind.tick, message.kind());
            try grt.std.testing.expectEqual(Origin.timer, message.origin);
            try grt.std.testing.expectEqual(@as(glib.time.instant.Time, 99), message.timestamp);
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

            TestCase.tagTracksBodyVariant() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.tickVariantUsesTickKind() catch |err| {
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
