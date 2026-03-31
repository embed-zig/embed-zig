const Context = @import("../Context.zig");

source_id: u32,
name: []const u8 = "",
payload: []const u8 = "",
ctx: Context.Type = null,

test "zux/event/bluetooth/PeripheralAdvertiseStart/unit_tests/default_optional_fields" {
    const std = @import("std");

    const event: @This() = .{
        .source_id = 1,
    };

    try std.testing.expectEqual(@as(u32, 1), event.source_id);
    try std.testing.expectEqualStrings("", event.name);
    try std.testing.expectEqualStrings("", event.payload);
    try std.testing.expect(event.ctx == null);
}
