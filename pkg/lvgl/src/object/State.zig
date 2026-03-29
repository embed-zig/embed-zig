const std = @import("std");
const binding = @import("../binding.zig");

pub const Value = u32;

pub const default: Value = @intCast(binding.LV_STATE_DEFAULT);
pub const pressed: Value = @intCast(binding.LV_STATE_PRESSED);
pub const focused: Value = @intCast(binding.LV_STATE_FOCUSED);
pub const disabled: Value = @intCast(binding.LV_STATE_DISABLED);
pub const checked: Value = @intCast(binding.LV_STATE_CHECKED);
pub const user_4: Value = @intCast(binding.LV_STATE_USER_4);
pub const any: Value = @intCast(binding.LV_STATE_ANY);

pub fn toRaw(value: Value) binding.State {
    return switch (@typeInfo(binding.State)) {
        .@"enum" => @enumFromInt(value),
        else => @as(binding.State, @intCast(value)),
    };
}

test "lvgl/unit_tests/object/State/constants_match_lvgl_defaults" {
    const testing = std.testing;

    try testing.expectEqual(@as(Value, 0), default);
    try testing.expect(pressed != 0);
    try testing.expect(any > pressed);
}
