const std = @import("std");
const binding = @import("../binding.zig");

pub fn screenRaw(handle: *const binding.Obj) ?*binding.Obj {
    return binding.lv_obj_get_screen(handle);
}

pub fn parentRaw(handle: *const binding.Obj) ?*binding.Obj {
    return binding.lv_obj_get_parent(handle);
}

pub fn childRaw(handle: *const binding.Obj, index: i32) ?*binding.Obj {
    return binding.lv_obj_get_child(handle, index);
}

pub fn childCount(handle: *const binding.Obj) u32 {
    return @intCast(binding.lv_obj_get_child_count(handle));
}

test "lvgl/unit_tests/object/Tree/raw_helpers_track_parent_and_child_ordering" {
    const testing = std.testing;
    const lvgl_testing = @import("../testing.zig");
    const Obj = @import("Obj.zig");

    var fixture = try lvgl_testing.Fixture.init();
    defer fixture.deinit();

    var screen = fixture.screen();
    var parent = Obj.create(&screen) orelse return error.OutOfMemory;
    defer parent.delete();

    _ = Obj.create(&parent) orelse return error.OutOfMemory;
    const second = Obj.create(&parent) orelse return error.OutOfMemory;

    try testing.expectEqual(@as(u32, 2), childCount(parent.raw()));
    try testing.expectEqual(parent.raw(), parentRaw(second.raw()).?);
    try testing.expectEqual(second.raw(), childRaw(parent.raw(), -1).?);
    try testing.expectEqual(screen.raw(), screenRaw(second.raw()).?);
}
