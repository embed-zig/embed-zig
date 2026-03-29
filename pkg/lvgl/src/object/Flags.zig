const std = @import("std");
const binding = @import("../binding.zig");

pub const Value = u32;

pub const hidden: Value = @intCast(binding.LV_OBJ_FLAG_HIDDEN);
pub const clickable: Value = @intCast(binding.LV_OBJ_FLAG_CLICKABLE);
pub const scrollable: Value = @intCast(binding.LV_OBJ_FLAG_SCROLLABLE);
pub const event_bubble: Value = @intCast(binding.LV_OBJ_FLAG_EVENT_BUBBLE);
pub const event_trickle: Value = @intCast(binding.LV_OBJ_FLAG_EVENT_TRICKLE);

pub fn toRaw(value: Value) binding.ObjFlag {
    return switch (@typeInfo(binding.ObjFlag)) {
        .@"enum" => @enumFromInt(value),
        else => @as(binding.ObjFlag, @intCast(value)),
    };
}

test "lvgl/unit_tests/object/Flags/constants_expose_expected_bit_masks" {
    const testing = std.testing;

    try testing.expect(hidden != 0);
    try testing.expect(clickable != 0);
    try testing.expect((event_bubble & event_trickle) == 0);
}
