const Context = @import("../Context.zig");

source_id: u32,
conn_handle: u16 = 0,
ctx: Context.Type = null,

test "zux/event/bluetooth/CentralDisconnect/unit_tests/default_optional_fields" {
    const std = @import("std");

    const event: @This() = .{
        .source_id = 1,
    };

    try std.testing.expectEqual(@as(u32, 1), event.source_id);
    try std.testing.expectEqual(@as(u16, 0), event.conn_handle);
    try std.testing.expect(event.ctx == null);
}
