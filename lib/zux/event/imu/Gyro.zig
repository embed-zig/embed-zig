const Context = @import("../Context.zig");

source_id: u32,
x: f32,
y: f32,
z: f32,
ctx: Context.Type = null,

test "zux/event/imu/Gyro/unit_tests/default_optional_fields" {
    const std = @import("std");

    const event: @This() = .{
        .source_id = 5,
        .x = 12.5,
        .y = 0.0,
        .z = -3.25,
    };

    try std.testing.expectEqual(@as(u32, 5), event.source_id);
    try std.testing.expectEqual(@as(f32, 12.5), event.x);
    try std.testing.expectEqual(@as(f32, 0.0), event.y);
    try std.testing.expectEqual(@as(f32, -3.25), event.z);
    try std.testing.expect(event.ctx == null);
}
