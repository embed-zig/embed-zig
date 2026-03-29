const std = @import("std");
const binding = @import("binding.zig");

const Self = @This();

handle: *binding.Anim,

pub const ExecXcb = binding.AnimExecXcb;

pub const repeat_infinite: u32 = binding.LV_ANIM_REPEAT_INFINITE;
pub const playtime_infinite: u32 = binding.LV_ANIM_PLAYTIME_INFINITE;
pub const pause_forever: u32 = binding.LV_ANIM_PAUSE_FOREVER;
pub const InitError = error{OutOfMemory};

pub fn init() InitError!Self {
    const handle = binding.embed_lv_anim_create() orelse return error.OutOfMemory;
    return .{ .handle = handle };
}

pub fn deinit(self: *Self) void {
    binding.embed_lv_anim_destroy(self.handle);
}

pub fn rawPtr(self: *Self) *binding.Anim {
    return self.handle;
}

pub fn rawConstPtr(self: *const Self) *const binding.Anim {
    return self.handle;
}

pub fn setVar(self: *Self, value: ?*anyopaque) void {
    binding.lv_anim_set_var(self.handle, value);
}

pub fn setDuration(self: *Self, duration_ms: u32) void {
    binding.lv_anim_set_duration(self.handle, duration_ms);
}

pub fn setDelay(self: *Self, delay_ms: u32) void {
    binding.lv_anim_set_delay(self.handle, delay_ms);
}

pub fn resumeAnim(self: *Self) void {
    binding.lv_anim_resume(self.handle);
}

pub fn pause(self: *Self) void {
    binding.lv_anim_pause(self.handle);
}

pub fn pauseFor(self: *Self, duration_ms: u32) void {
    binding.lv_anim_pause_for(self.handle, duration_ms);
}

pub fn isPaused(self: *Self) bool {
    return binding.lv_anim_is_paused(self.handle);
}

pub fn setValues(self: *Self, start_value: i32, end_value: i32) void {
    binding.lv_anim_set_values(self.handle, start_value, end_value);
}

pub fn setReverseDuration(self: *Self, duration_ms: u32) void {
    binding.lv_anim_set_reverse_duration(self.handle, duration_ms);
}

pub fn setReverseDelay(self: *Self, delay_ms: u32) void {
    binding.lv_anim_set_reverse_delay(self.handle, delay_ms);
}

pub fn setRepeatCount(self: *Self, count: u32) void {
    binding.lv_anim_set_repeat_count(self.handle, count);
}

pub fn setRepeatDelay(self: *Self, delay_ms: u32) void {
    binding.lv_anim_set_repeat_delay(self.handle, delay_ms);
}

pub fn setEarlyApply(self: *Self, enabled: bool) void {
    binding.lv_anim_set_early_apply(self.handle, enabled);
}

pub fn setExecCb(self: *Self, exec_cb: ExecXcb) void {
    binding.lv_anim_set_exec_cb(self.handle, exec_cb);
}

pub fn start(self: *const Self) ?*binding.Anim {
    return binding.lv_anim_start(self.handle);
}

pub fn deleteAll() void {
    binding.lv_anim_delete_all();
}

test "lvgl/unit_tests/Anim/descriptor_configures_core_fields" {
    const testing = std.testing;

    var anim = try Self.init();
    defer anim.deinit();
    anim.setDuration(120);
    anim.setDelay(8);
    anim.setValues(3, 9);
    anim.setReverseDuration(42);
    anim.setReverseDelay(7);
    anim.setRepeatCount(2);
    anim.setRepeatDelay(5);
    anim.setEarlyApply(true);

    try testing.expectEqual(@as(i32, 120), binding.embed_lv_anim_get_duration(anim.rawConstPtr()));
    try testing.expectEqual(@as(i32, -8), binding.embed_lv_anim_get_act_time(anim.rawConstPtr()));
    try testing.expectEqual(@as(i32, 3), binding.embed_lv_anim_get_start_value(anim.rawConstPtr()));
    try testing.expectEqual(@as(i32, 9), binding.embed_lv_anim_get_end_value(anim.rawConstPtr()));
    try testing.expectEqual(@as(u32, 42), binding.embed_lv_anim_get_reverse_duration(anim.rawConstPtr()));
    try testing.expectEqual(@as(u32, 7), binding.embed_lv_anim_get_reverse_delay(anim.rawConstPtr()));
    try testing.expectEqual(@as(u32, 2), binding.embed_lv_anim_get_repeat_count(anim.rawConstPtr()));
    try testing.expectEqual(@as(u32, 5), binding.embed_lv_anim_get_repeat_delay(anim.rawConstPtr()));
    try testing.expect(binding.embed_lv_anim_get_early_apply(anim.rawConstPtr()) == 1);
}

test "lvgl/unit_tests/Anim/pause_state_toggles_through_lvgl_api" {
    const testing = std.testing;

    var anim = try Self.init();
    defer anim.deinit();

    try testing.expect(!anim.isPaused());
    anim.pause();
    try testing.expect(anim.isPaused());
    anim.resumeAnim();
    try testing.expect(!anim.isPaused());
}
