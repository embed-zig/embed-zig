const binding = @import("binding.zig");
const Display = @import("Display.zig");
const Obj = @import("object/Obj.zig");

const Self = @This();

handle: *binding.Indev,

/// Mirrors `lv_indev_type_t`.
pub const Type = enum(c_int) {
    none = 0,
    pointer = 1,
    keypad = 2,
    button = 3,
    encoder = 4,
};

/// Mirrors `lv_indev_state_t`.
pub const State = enum(c_int) {
    released = 0,
    pressed = 1,
};

/// Mirrors `lv_indev_mode_t`.
pub const Mode = enum(c_int) {
    none = 0,
    timer = 1,
    event = 2,
};

pub const Data = binding.IndevData;
pub const ReadCb = binding.IndevReadCb;
pub const KeyRemapCb = binding.IndevKeyRemapCb;
pub const Group = binding.Group;
pub const Key = binding.Key;

pub fn fromRaw(handle: *binding.Indev) Self {
    return .{ .handle = handle };
}

pub fn create() ?Self {
    const handle = binding.lv_indev_create() orelse return null;
    return fromRaw(handle);
}

pub fn raw(self: *const Self) *binding.Indev {
    return self.handle;
}

pub fn delete(self: *Self) void {
    binding.lv_indev_delete(self.handle);
}

pub fn next(prev: ?*const Self) ?Self {
    const p: ?*binding.Indev = if (prev) |q| q.handle else null;
    const handle = binding.lv_indev_get_next(p) orelse return null;
    return fromRaw(handle);
}

pub fn read(self: *Self) void {
    binding.lv_indev_read(self.handle);
}

pub fn active() ?Self {
    const handle = binding.lv_indev_active() orelse return null;
    return fromRaw(handle);
}

pub fn enable(self: ?*const Self, on: bool) void {
    const p: ?*binding.Indev = if (self) |s| s.handle else null;
    binding.lv_indev_enable(p, on);
}

pub fn setType(self: *const Self, t: Type) void {
    binding.lv_indev_set_type(self.handle, @enumFromInt(@intFromEnum(t)));
}

pub fn getType(self: *const Self) Type {
    return @enumFromInt(@intFromEnum(binding.lv_indev_get_type(self.handle)));
}

pub fn setReadCb(self: *const Self, read_cb: ReadCb) void {
    binding.lv_indev_set_read_cb(self.handle, read_cb);
}

pub fn getReadCb(self: *Self) ReadCb {
    return binding.lv_indev_get_read_cb(self.handle);
}

pub fn setUserData(self: *const Self, user_data: ?*anyopaque) void {
    binding.lv_indev_set_user_data(self.handle, user_data);
}

pub fn getUserData(self: *const Self) ?*anyopaque {
    return binding.lv_indev_get_user_data(self.handle);
}

pub fn setDriverData(self: *const Self, driver_data: ?*anyopaque) void {
    binding.lv_indev_set_driver_data(self.handle, driver_data);
}

pub fn getDriverData(self: *const Self) ?*anyopaque {
    return binding.lv_indev_get_driver_data(self.handle);
}

pub fn setDisplay(self: *const Self, display: ?*const Display) void {
    binding.lv_indev_set_display(self.handle, if (display) |d| d.raw() else null);
}

pub fn getDisplay(self: *const Self) ?Display {
    const handle = binding.lv_indev_get_display(self.handle) orelse return null;
    return Display.fromRaw(handle);
}

pub fn setLongPressTime(self: *const Self, ms: u16) void {
    binding.lv_indev_set_long_press_time(self.handle, ms);
}

pub fn setLongPressRepeatTime(self: *const Self, ms: u16) void {
    binding.lv_indev_set_long_press_repeat_time(self.handle, ms);
}

pub fn setScrollLimit(self: *const Self, pixels: u8) void {
    binding.lv_indev_set_scroll_limit(self.handle, pixels);
}

pub fn setScrollThrow(self: *const Self, slow_down_percent: u8) void {
    binding.lv_indev_set_scroll_throw(self.handle, slow_down_percent);
}

pub fn reset(self: *Self, obj: ?Obj) void {
    binding.lv_indev_reset(self.handle, if (obj) |o| o.raw() else null);
}

pub fn resetAll(obj: ?Obj) void {
    binding.lv_indev_reset(null, if (obj) |o| o.raw() else null);
}

pub fn stopProcessing(self: *Self) void {
    binding.lv_indev_stop_processing(self.handle);
}

pub fn resetLongPress(self: *Self) void {
    binding.lv_indev_reset_long_press(self.handle);
}

pub fn setCursor(self: *const Self, cursor_obj: ?Obj) void {
    binding.lv_indev_set_cursor(self.handle, if (cursor_obj) |o| o.raw() else null);
}

pub fn getCursor(self: *const Self) ?Obj {
    const handle = binding.lv_indev_get_cursor(self.handle) orelse return null;
    return Obj.fromRaw(handle);
}

pub fn setGroup(self: *const Self, group: ?*Group) void {
    binding.lv_indev_set_group(self.handle, group);
}

pub fn getGroup(self: *const Self) ?*Group {
    return binding.lv_indev_get_group(self.handle);
}

/// `points` is stored by reference; keep the slice valid for as long as this indev may read button indices.
pub fn setButtonPoints(self: *const Self, points: []const binding.Point) void {
    binding.lv_indev_set_button_points(self.handle, points.ptr);
}

pub fn getPoint(self: *const Self) binding.Point {
    var p: binding.Point = undefined;
    binding.lv_indev_get_point(self.handle, &p);
    return p;
}

pub fn getKey(self: *const Self) u32 {
    return binding.lv_indev_get_key(self.handle);
}

pub fn scrollDir(self: *const Self) binding.Dir {
    return binding.lv_indev_get_scroll_dir(self.handle);
}

pub fn scrollObj(self: *const Self) ?Obj {
    const handle = binding.lv_indev_get_scroll_obj(self.handle) orelse return null;
    return Obj.fromRaw(handle);
}

pub fn vector(self: *const Self) binding.Point {
    var p: binding.Point = undefined;
    binding.lv_indev_get_vect(self.handle, &p);
    return p;
}

pub fn waitRelease(self: *Self) void {
    binding.lv_indev_wait_release(self.handle);
}

pub fn activeObj() ?Obj {
    const handle = binding.lv_indev_get_active_obj() orelse return null;
    return Obj.fromRaw(handle);
}

pub fn readTimer(self: *const Self) ?*binding.Timer {
    return binding.lv_indev_get_read_timer(self.handle);
}

pub fn setMode(self: *const Self, mode: Mode) void {
    binding.lv_indev_set_mode(self.handle, @enumFromInt(@intFromEnum(mode)));
}

pub fn getMode(self: *const Self) Mode {
    return @enumFromInt(@intFromEnum(binding.lv_indev_get_mode(self.handle)));
}

pub fn searchObj(root: Obj, point: *binding.Point) ?Obj {
    const handle = binding.lv_indev_search_obj(root.raw(), point) orelse return null;
    return Obj.fromRaw(handle);
}

pub fn addEventCb(
    self: *const Self,
    event_cb: binding.EventCallback,
    filter: binding.EventCode,
    user_data: ?*anyopaque,
) void {
    binding.lv_indev_add_event_cb(self.handle, event_cb, filter, user_data);
}

pub fn eventCount(self: *Self) u32 {
    return binding.lv_indev_get_event_count(self.handle);
}

pub fn eventDsc(self: *Self, index: u32) ?*binding.EventDsc {
    return binding.lv_indev_get_event_dsc(self.handle, index);
}

pub fn removeEvent(self: *Self, index: u32) bool {
    return binding.lv_indev_remove_event(self.handle, index);
}

pub fn removeEventCbWithUserData(
    self: *Self,
    event_cb: binding.EventCallback,
    user_data: ?*anyopaque,
) u32 {
    return binding.lv_indev_remove_event_cb_with_user_data(self.handle, event_cb, user_data);
}

pub fn sendEvent(self: *Self, code: binding.EventCode, param: ?*anyopaque) binding.Result {
    return binding.lv_indev_send_event(self.handle, code, param orelse null);
}

pub fn setKeyRemapCb(self: *const Self, remap_cb: KeyRemapCb) void {
    binding.lv_indev_set_key_remap_cb(self.handle, remap_cb);
}

test "lvgl/unit_tests/Indev/raw_handle_roundtrip" {
    const testing = @import("std").testing;

    const raw_handle: *binding.Indev = @ptrFromInt(1);
    const indev = Self.fromRaw(raw_handle);

    try testing.expectEqual(raw_handle, indev.raw());

    _ = Self.setDisplay;
    _ = Self.getDisplay;
}
