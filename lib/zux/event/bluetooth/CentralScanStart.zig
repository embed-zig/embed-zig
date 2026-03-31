const Context = @import("../Context.zig");

source_id: u32,
active: bool = true,
service_uuid: ?[]const u8 = null,
ctx: Context.Type = null,

test "zux/event/bluetooth/CentralScanStart/unit_tests/default_optional_fields" {
    const std = @import("std");

    const event: @This() = .{
        .source_id = 1,
    };

    try std.testing.expectEqual(@as(u32, 1), event.source_id);
    try std.testing.expect(event.active);
    try std.testing.expect(event.service_uuid == null);
    try std.testing.expect(event.ctx == null);
}
