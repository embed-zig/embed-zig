const Context = @import("../Context.zig");

source_id: u32,
button_id: u32,
pressed: bool,
ctx: Context.Type = null,

test "zux/event/button/ButtonGroup/unit_tests/default_ctx_is_null" {
    const std = @import("std");

    const event: @This() = .{
        .source_id = 7,
        .button_id = 3,
        .pressed = false,
    };

    try std.testing.expectEqual(@as(u32, 7), event.source_id);
    try std.testing.expectEqual(@as(u32, 3), event.button_id);
    try std.testing.expect(!event.pressed);
    try std.testing.expect(event.ctx == null);
}
