const std = @import("std");
const event = @import("../event.zig");

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

test "zux/pipeline/Message/unit_tests/tag_tracks_body_variant" {
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

    try std.testing.expectEqual(Kind.button_gesture, message.kind());
    try std.testing.expectEqual(Origin.source, message.origin);
    try std.testing.expectEqual(@as(i128, 42), message.timestamp_ns);
}

test "zux/pipeline/Message/unit_tests/tick_variant_uses_tick_kind" {
    const message: Message = .{
        .origin = .timer,
        .timestamp_ns = 99,
        .body = .{
            .tick = .{},
        },
    };

    try std.testing.expectEqual(Kind.tick, message.kind());
    try std.testing.expectEqual(Origin.timer, message.origin);
    try std.testing.expectEqual(@as(i128, 99), message.timestamp_ns);
}
