const std = @import("std");
const binding = @import("../binding.zig");
const Obj = @import("../object/Obj.zig");
const Label = @import("Label.zig");

const Self = @This();

handle: *binding.Obj,

pub fn fromRaw(handle: *binding.Obj) Self {
    return .{ .handle = handle };
}

pub fn fromObj(obj: Obj) Self {
    return fromRaw(obj.raw());
}

pub fn create(parent_obj: *const Obj) ?Self {
    const handle = binding.lv_button_create(parent_obj.raw()) orelse return null;
    return fromRaw(handle);
}

pub fn raw(self: *const Self) *binding.Obj {
    return self.handle;
}

pub fn asObj(self: *const Self) Obj {
    return Obj.fromRaw(self.handle);
}

pub fn createLabel(self: *const Self) ?Label {
    const obj = self.asObj();
    return Label.create(&obj);
}

test "lvgl/unit_tests/widget/Button/composes_object_layer_and_can_host_child_label" {
    const testing = std.testing;
    const lvgl_testing = @import("../testing.zig");

    var fixture = try lvgl_testing.Fixture.init();
    defer fixture.deinit();

    var screen = fixture.screen();
    var button = Self.create(&screen) orelse return error.OutOfMemory;
    var button_obj = button.asObj();
    defer button_obj.delete();

    var label = button.createLabel() orelse return error.OutOfMemory;
    label.setText("press");

    try testing.expectEqual(screen.raw(), button_obj.parent().?.raw());
    try testing.expectEqual(@as(u32, 1), button_obj.childCount());
    try testing.expectEqual(button_obj.raw(), label.asObj().parent().?.raw());
    try testing.expectEqualStrings("press", std.mem.span(label.text()));
}

test "lvgl/unit_tests/widget/Button/object_api_remains_the_source_of_generic_behavior" {
    const testing = std.testing;
    const lvgl_testing = @import("../testing.zig");
    const Flags = @import("../object/Flags.zig");

    var fixture = try lvgl_testing.Fixture.init();
    defer fixture.deinit();

    var screen = fixture.screen();
    var button = Self.create(&screen) orelse return error.OutOfMemory;
    var obj = button.asObj();
    defer obj.delete();

    obj.setPos(21, 13);
    obj.setSize(80, 32);
    obj.addFlag(Flags.clickable);
    obj.updateLayout();

    try testing.expectEqual(@as(i32, 21), obj.x());
    try testing.expectEqual(@as(i32, 13), obj.y());
    try testing.expectEqual(@as(i32, 80), obj.width());
    try testing.expectEqual(@as(i32, 32), obj.height());
    try testing.expect(obj.hasFlag(Flags.clickable));
}

test "lvgl/unit_tests/widget/Button/raw_and_object_roundtrip_preserve_handle" {
    const testing = std.testing;

    const raw_handle: *binding.Obj = @ptrFromInt(1);
    const button = Self.fromRaw(raw_handle);

    try testing.expectEqual(raw_handle, button.raw());
    try testing.expectEqual(raw_handle, button.asObj().raw());
}
