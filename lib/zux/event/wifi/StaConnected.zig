const Context = @import("../Context.zig");

source_id: u32,
ssid: []const u8 = "",
rssi: ?i16 = null,
ctx: Context.Type = null,

test "zux/event/wifi/StaConnected/unit_tests/default_optional_fields" {
    const std = @import("std");

    const event: @This() = .{
        .source_id = 1,
    };

    try std.testing.expectEqual(@as(u32, 1), event.source_id);
    try std.testing.expectEqualStrings("", event.ssid);
    try std.testing.expect(event.rssi == null);
    try std.testing.expect(event.ctx == null);
}
