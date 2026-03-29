const std = @import("std");
const binding = @import("binding.zig");

const Self = @This();

fn styleProp(value: anytype) binding.StyleProp {
    return switch (@typeInfo(binding.StyleProp)) {
        .@"enum" => @enumFromInt(value),
        else => @as(binding.StyleProp, @intCast(value)),
    };
}

raw: binding.Style,

pub const width_prop: binding.StyleProp = styleProp(binding.LV_STYLE_WIDTH);

pub fn init() Self {
    var self: Self = .{ .raw = undefined };
    binding.lv_style_init(&self.raw);
    return self;
}

pub fn deinit(self: *Self) void {
    binding.lv_style_reset(&self.raw);
}

pub fn reset(self: *Self) void {
    binding.lv_style_reset(&self.raw);
}

pub fn copyFrom(self: *Self, other: *const Self) void {
    binding.lv_style_copy(&self.raw, &other.raw);
}

pub fn mergeFrom(self: *Self, other: *const Self) void {
    binding.lv_style_merge(&self.raw, &other.raw);
}

pub fn setWidth(self: *Self, width: i32) void {
    binding.lv_style_set_width(&self.raw, width);
}

pub fn isEmpty(self: *const Self) bool {
    return binding.lv_style_is_empty(&self.raw);
}

pub fn rawPtr(self: *Self) *binding.Style {
    return &self.raw;
}

pub fn rawConstPtr(self: *const Self) *const binding.Style {
    return &self.raw;
}

test "lvgl/unit_tests/Style/lifecycle_starts_empty" {
    const testing = std.testing;

    binding.lv_init();
    defer binding.lv_deinit();

    var a = Self.init();
    defer a.deinit();
    try testing.expect(a.isEmpty());

    var b = Self.init();
    defer b.deinit();
    b.copyFrom(&a);
    try testing.expect(b.isEmpty());

    b.setWidth(24);
    try testing.expect(!b.isEmpty());

    b.mergeFrom(&a);
    try testing.expect(!b.isEmpty());
}
