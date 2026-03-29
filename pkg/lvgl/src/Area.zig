const std = @import("std");
const binding = @import("binding.zig");

const Self = @This();

x1: i32,
y1: i32,
x2: i32,
y2: i32,

pub fn init(x1: i32, y1: i32, x2: i32, y2: i32) Self {
    var raw: binding.Area = undefined;
    binding.lv_area_set(&raw, x1, y1, x2, y2);
    return fromBinding(raw);
}

pub fn width(self: *const Self) i32 {
    var raw = self.toBinding();
    return binding.lv_area_get_width(&raw);
}

pub fn height(self: *const Self) i32 {
    var raw = self.toBinding();
    return binding.lv_area_get_height(&raw);
}

pub fn size(self: *const Self) u32 {
    var raw = self.toBinding();
    return binding.lv_area_get_size(&raw);
}

pub fn setWidth(self: *Self, new_width: i32) void {
    var raw = self.toBinding();
    binding.lv_area_set_width(&raw, new_width);
    self.* = fromBinding(raw);
}

pub fn setHeight(self: *Self, new_height: i32) void {
    var raw = self.toBinding();
    binding.lv_area_set_height(&raw, new_height);
    self.* = fromBinding(raw);
}

pub fn increase(self: *Self, width_extra: i32, height_extra: i32) void {
    var raw = self.toBinding();
    binding.lv_area_increase(&raw, width_extra, height_extra);
    self.* = fromBinding(raw);
}

pub fn move(self: *Self, x_ofs: i32, y_ofs: i32) void {
    var raw = self.toBinding();
    binding.lv_area_move(&raw, x_ofs, y_ofs);
    self.* = fromBinding(raw);
}

pub fn toBinding(self: *const Self) binding.Area {
    return .{
        .x1 = self.x1,
        .y1 = self.y1,
        .x2 = self.x2,
        .y2 = self.y2,
    };
}

pub fn fromBinding(raw: binding.Area) Self {
    return .{
        .x1 = raw.x1,
        .y1 = raw.y1,
        .x2 = raw.x2,
        .y2 = raw.y2,
    };
}

test "lvgl/unit_tests/Area/helpers_preserve_lvgl_semantics" {
    const testing = std.testing;

    var area = Self.init(2, 4, 6, 9);
    try testing.expectEqual(@as(i32, 5), area.width());
    try testing.expectEqual(@as(i32, 6), area.height());
    try testing.expectEqual(@as(u32, 30), area.size());

    area.setWidth(3);
    try testing.expectEqual(@as(i32, 3), area.width());

    area.setHeight(2);
    try testing.expectEqual(@as(i32, 2), area.height());

    area.move(10, -2);
    try testing.expectEqual(@as(i32, 12), area.x1);
    try testing.expectEqual(@as(i32, 2), area.y1);
}
