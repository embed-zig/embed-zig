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
timestamp_ns: i128 = 0,
body: Event,

pub fn kind(self: Message) Kind {
    return switch (self.body) {
        inline else => |_, active_kind| active_kind,
    };
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn tagTracksBodyVariant(testing: anytype) !void {
            const message: Message = .{
                .origin = .source,
                .timestamp_ns = 42,
                .body = .{
                    .button_gesture = .{
                        .source_id = 1,
                        .gesture = .{ .click = 1 },
                    },
                },
            };

            try testing.expectEqual(Kind.button_gesture, message.kind());
            try testing.expectEqual(Origin.source, message.origin);
            try testing.expectEqual(@as(i128, 42), message.timestamp_ns);
        }

        fn tickVariantUsesTickKind(testing: anytype) !void {
            const message: Message = .{
                .origin = .timer,
                .timestamp_ns = 99,
                .body = .{
                    .tick = .{},
                },
            };

            try testing.expectEqual(Kind.tick, message.kind());
            try testing.expectEqual(Origin.timer, message.origin);
            try testing.expectEqual(@as(i128, 99), message.timestamp_ns);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            TestCase.tagTracksBodyVariant(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.tickVariantUsesTickKind(testing) catch |err| {
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
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
