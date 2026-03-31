const Context = @import("../Context.zig");

source_id: u32,
ctx: Context.Type = null,

test "zux/event/bluetooth/PeripheralAdvertiseStop/unit_tests/default_ctx_is_null" {
    const std = @import("std");

    const event: @This() = .{
        .source_id = 1,
    };

    try std.testing.expectEqual(@as(u32, 1), event.source_id);
    try std.testing.expect(event.ctx == null);
}
