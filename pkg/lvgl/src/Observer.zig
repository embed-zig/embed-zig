const std = @import("std");
const binding = @import("binding.zig");

const Self = @This();

handle: *binding.Observer,

pub fn fromRaw(handle: *binding.Observer) Self {
    return .{ .handle = handle };
}

pub fn raw(self: *const Self) *binding.Observer {
    return self.handle;
}

pub fn remove(self: *Self) void {
    binding.lv_observer_remove(self.handle);
}

pub fn target(self: *const Self) ?*anyopaque {
    return binding.lv_observer_get_target(self.handle);
}

pub fn userData(self: *const Self) ?*anyopaque {
    return binding.lv_observer_get_user_data(self.handle);
}

test "lvgl/unit_tests/Observer/raw_handle_roundtrip" {
    const testing = std.testing;

    const raw_handle: *binding.Observer = @ptrFromInt(1);
    const observer = Self.fromRaw(raw_handle);

    try testing.expectEqual(raw_handle, observer.raw());

    _ = Self.remove;
    _ = Self.target;
    _ = Self.userData;
}
