const std = @import("std");
const binding = @import("../binding.zig");
const Obj = @import("../object/Obj.zig");

const Self = @This();

handle: *binding.Obj,

pub const LongMode = binding.LabelLongMode;
pub const long_mode_wrap: LongMode = binding.LV_LABEL_LONG_MODE_WRAP;
pub const long_mode_dots: LongMode = binding.LV_LABEL_LONG_MODE_DOTS;
pub const long_mode_scroll: LongMode = binding.LV_LABEL_LONG_MODE_SCROLL;
pub const long_mode_scroll_circular: LongMode = binding.LV_LABEL_LONG_MODE_SCROLL_CIRCULAR;
pub const long_mode_clip: LongMode = binding.LV_LABEL_LONG_MODE_CLIP;

pub fn fromRaw(handle: *binding.Obj) Self {
    return .{ .handle = handle };
}

pub fn fromObj(obj: Obj) Self {
    return fromRaw(obj.raw());
}

pub fn create(parent_obj: *const Obj) ?Self {
    const handle = binding.lv_label_create(parent_obj.raw()) orelse return null;
    return fromRaw(handle);
}

pub fn raw(self: *const Self) *binding.Obj {
    return self.handle;
}

pub fn asObj(self: *const Self) Obj {
    return Obj.fromRaw(self.handle);
}

pub fn setText(self: *const Self, new_text: [:0]const u8) void {
    binding.lv_label_set_text(self.handle, new_text.ptr);
}

pub fn setTextStatic(self: *const Self, new_text: [:0]const u8) void {
    binding.lv_label_set_text_static(self.handle, new_text.ptr);
}

pub fn text(self: *const Self) [*:0]const u8 {
    return @ptrCast(binding.lv_label_get_text(self.handle));
}

pub fn setLongMode(self: *const Self, mode: LongMode) void {
    binding.lv_label_set_long_mode(self.handle, mode);
}

pub fn longMode(self: *const Self) LongMode {
    return binding.lv_label_get_long_mode(self.handle);
}

test "lvgl/unit_tests/widget/Label/composes_object_layer_and_stores_text" {
    const testing = std.testing;
    const lvgl_testing = @import("../testing.zig");

    var fixture = try lvgl_testing.Fixture.init();
    defer fixture.deinit();

    var screen = fixture.screen();
    var label = Self.create(&screen) orelse return error.OutOfMemory;
    var obj = label.asObj();
    defer obj.delete();

    label.setText("hello");

    try testing.expectEqual(screen.raw(), obj.parent().?.raw());
    try testing.expectEqualStrings("hello", std.mem.span(label.text()));
}

test "lvgl/unit_tests/widget/Label/long_mode_roundtrips_through_wrapper" {
    const testing = std.testing;
    const lvgl_testing = @import("../testing.zig");

    var fixture = try lvgl_testing.Fixture.init();
    defer fixture.deinit();

    var screen = fixture.screen();
    var label = Self.create(&screen) orelse return error.OutOfMemory;
    var obj = label.asObj();
    defer obj.delete();

    label.setLongMode(long_mode_scroll);

    try testing.expectEqual(long_mode_scroll, label.longMode());
}

test "lvgl/unit_tests/widget/Label/static_text_still_participates_in_object_api" {
    const testing = std.testing;
    const lvgl_testing = @import("../testing.zig");

    var fixture = try lvgl_testing.Fixture.init();
    defer fixture.deinit();

    var screen = fixture.screen();
    var label = Self.create(&screen) orelse return error.OutOfMemory;
    var obj = label.asObj();
    defer obj.delete();

    label.setTextStatic("fixed");

    obj.setPos(14, 9);
    obj.updateLayout();

    try testing.expectEqualStrings("fixed", std.mem.span(label.text()));
    try testing.expectEqual(@as(i32, 14), obj.x());
    try testing.expectEqual(@as(i32, 9), obj.y());
}
