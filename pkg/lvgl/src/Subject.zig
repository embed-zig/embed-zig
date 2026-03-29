const std = @import("std");
const binding = @import("binding.zig");

const Self = @This();

handle: *binding.Subject,

pub const Type = binding.SubjectType;
pub const InitError = error{OutOfMemory};

pub fn rawPtr(self: *Self) *binding.Subject {
    return self.handle;
}

pub fn rawConstPtr(self: *const Self) *const binding.Subject {
    return self.handle;
}

pub fn initInt(value: i32) InitError!Self {
    const handle = binding.embed_lv_subject_create() orelse return error.OutOfMemory;
    binding.lv_subject_init_int(handle, value);
    return .{ .handle = handle };
}

pub fn initPointer(value: ?*anyopaque) InitError!Self {
    const handle = binding.embed_lv_subject_create() orelse return error.OutOfMemory;
    binding.lv_subject_init_pointer(handle, value);
    return .{ .handle = handle };
}

pub fn initString(buffer: [:0]u8, prev_buffer: ?[:0]u8, initial_value: [:0]const u8) InitError!Self {
    const handle = binding.embed_lv_subject_create() orelse return error.OutOfMemory;
    const prev_ptr = if (prev_buffer) |buf| buf.ptr else null;
    binding.lv_subject_init_string(handle, buffer.ptr, prev_ptr, buffer.len, initial_value.ptr);
    return .{ .handle = handle };
}

pub fn deinit(self: *Self) void {
    binding.lv_subject_deinit(self.handle);
    binding.embed_lv_subject_destroy(self.handle);
}

pub fn setInt(self: *Self, value: i32) void {
    binding.lv_subject_set_int(self.handle, value);
}

pub fn getInt(self: *Self) i32 {
    return binding.lv_subject_get_int(self.handle);
}

pub fn previousInt(self: *Self) i32 {
    return binding.lv_subject_get_previous_int(self.handle);
}

pub fn setMinInt(self: *Self, value: i32) void {
    binding.lv_subject_set_min_value_int(self.handle, value);
}

pub fn setMaxInt(self: *Self, value: i32) void {
    binding.lv_subject_set_max_value_int(self.handle, value);
}

pub fn setPointer(self: *Self, value: ?*anyopaque) void {
    binding.lv_subject_set_pointer(self.handle, value);
}

pub fn getPointer(self: *Self) ?*const anyopaque {
    return binding.lv_subject_get_pointer(self.handle);
}

pub fn previousPointer(self: *Self) ?*const anyopaque {
    return binding.lv_subject_get_previous_pointer(self.handle);
}

pub fn copyString(self: *Self, value: [:0]const u8) void {
    binding.lv_subject_copy_string(self.handle, value.ptr);
}

pub fn getString(self: *Self) [*:0]const u8 {
    return binding.lv_subject_get_string(self.handle);
}

pub fn previousString(self: *Self) ?[*:0]const u8 {
    return binding.lv_subject_get_previous_string(self.handle);
}

test "lvgl/unit_tests/Subject/integer_subject_tracks_current_and_previous_values" {
    const testing = std.testing;

    var subject = try Self.initInt(12);
    defer subject.deinit();

    try testing.expectEqual(@as(i32, 12), subject.getInt());

    subject.setInt(34);

    try testing.expectEqual(@as(i32, 34), subject.getInt());
    try testing.expectEqual(@as(i32, 12), subject.previousInt());
}

test "lvgl/unit_tests/Subject/pointer_subject_tracks_previous_pointer_value" {
    const testing = std.testing;

    var first: u8 = 1;
    var second: u8 = 2;
    var subject = try Self.initPointer(&first);
    defer subject.deinit();

    try testing.expectEqual(@as(?*const anyopaque, @ptrCast(&first)), subject.getPointer());
    try testing.expectEqual(@as(?*const anyopaque, @ptrCast(&first)), subject.previousPointer());

    subject.setPointer(&second);

    try testing.expectEqual(@as(?*const anyopaque, @ptrCast(&second)), subject.getPointer());
    try testing.expectEqual(@as(?*const anyopaque, @ptrCast(&first)), subject.previousPointer());
}

test "lvgl/unit_tests/Subject/string_subject_copies_into_owned_buffers" {
    const testing = std.testing;

    var current_buffer = [_:0]u8{0} ** 16;
    var previous_buffer = [_:0]u8{0} ** 16;
    var subject = try Self.initString(current_buffer[0.. :0], previous_buffer[0.. :0], "hi");
    defer subject.deinit();

    subject.copyString("bye");

    try testing.expectEqualStrings("bye", std.mem.span(subject.getString()));
    try testing.expectEqualStrings("hi", std.mem.span(subject.previousString().?));
}
