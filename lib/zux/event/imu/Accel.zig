const Context = @import("../Context.zig");

source_id: u32,
x: f32,
y: f32,
z: f32,
ctx: Context.Type = null,

test "zux/event/imu/Accel/unit_tests/default_optional_fields" {
    const std = @import("std");

    const event: @This() = .{
        .source_id = 5,
        .x = 0.25,
        .y = -0.5,
        .z = 1.0,
    };

    try std.testing.expectEqual(@as(u32, 5), event.source_id);
    try std.testing.expectEqual(@as(f32, 0.25), event.x);
    try std.testing.expectEqual(@as(f32, -0.5), event.y);
    try std.testing.expectEqual(@as(f32, 1.0), event.z);
    try std.testing.expect(event.ctx == null);
}
