const binding = @import("binding.zig");
const Obj = @import("object/Obj.zig");
const testing_api = @import("testing");

const Self = @This();

handle: *binding.Display,

pub const Rotation = enum(c_int) {
    deg0 = 0,
    deg90 = 1,
    deg180 = 2,
    deg270 = 3,
};

pub fn fromRaw(handle: *binding.Display) Self {
    return .{ .handle = handle };
}

pub fn create(horizontal: i32, vertical: i32) ?Self {
    const handle = binding.lv_display_create(horizontal, vertical) orelse return null;
    return fromRaw(handle);
}

pub fn raw(self: *const Self) *binding.Display {
    return self.handle;
}

pub fn delete(self: *Self) void {
    binding.lv_display_delete(self.handle);
}

pub fn setDefault(self: *const Self) void {
    binding.lv_display_set_default(self.handle);
}

pub fn getDefault() ?Self {
    const handle = binding.lv_display_get_default() orelse return null;
    return fromRaw(handle);
}

pub fn activeScreen(self: *const Self) Obj {
    const handle = binding.lv_display_get_screen_active(self.handle) orelse {
        @panic("LVGL display did not expose an active screen");
    };
    return Obj.fromRaw(handle);
}

pub fn setResolution(self: *const Self, horizontal: i32, vertical: i32) void {
    binding.lv_display_set_resolution(self.handle, horizontal, vertical);
}

pub fn setPhysicalResolution(self: *const Self, horizontal: i32, vertical: i32) void {
    binding.lv_display_set_physical_resolution(self.handle, horizontal, vertical);
}

pub fn setOffset(self: *const Self, x: i32, y: i32) void {
    binding.lv_display_set_offset(self.handle, x, y);
}

pub fn setRotation(self: *const Self, new_rotation: Rotation) void {
    binding.lv_display_set_rotation(self.handle, @as(binding.DisplayRotation, @intCast(@intFromEnum(new_rotation))));
}

pub fn setDpi(self: *const Self, new_dpi: i32) void {
    binding.lv_display_set_dpi(self.handle, new_dpi);
}

pub fn width(self: *const Self) i32 {
    return binding.lv_display_get_horizontal_resolution(self.handle);
}

pub fn height(self: *const Self) i32 {
    return binding.lv_display_get_vertical_resolution(self.handle);
}

pub fn originalWidth(self: *const Self) i32 {
    return binding.lv_display_get_original_horizontal_resolution(self.handle);
}

pub fn originalHeight(self: *const Self) i32 {
    return binding.lv_display_get_original_vertical_resolution(self.handle);
}

pub fn physicalWidth(self: *const Self) i32 {
    return binding.lv_display_get_physical_horizontal_resolution(self.handle);
}

pub fn physicalHeight(self: *const Self) i32 {
    return binding.lv_display_get_physical_vertical_resolution(self.handle);
}

pub fn offsetX(self: *const Self) i32 {
    return binding.lv_display_get_offset_x(self.handle);
}

pub fn offsetY(self: *const Self) i32 {
    return binding.lv_display_get_offset_y(self.handle);
}

pub fn rotation(self: *const Self) Rotation {
    return @enumFromInt(binding.lv_display_get_rotation(self.handle));
}

pub fn dpi(self: *const Self) i32 {
    return binding.lv_display_get_dpi(self.handle);
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const Impl = struct {
        fn raw_handle_roundtrip(_: *testing_api.T, _: lib.mem.Allocator) !void {
            const testing = lib.testing;

            const raw_handle: *binding.Display = @ptrFromInt(1);
            const display = Self.fromRaw(raw_handle);

            try testing.expectEqual(raw_handle, display.raw());

            _ = Self.activeScreen;
        }

        fn runtime_properties_roundtrip_through_wrapper(_: *testing_api.T, _: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const lvgl_testing = @import("testing.zig");

            var fixture = try lvgl_testing.Fixture.init();
            defer fixture.deinit();

            var display = fixture.display;
            display.setResolution(200, 100);
            display.setPhysicalResolution(220, 140);
            display.setOffset(7, 9);
            const default_display = Self.getDefault() orelse return error.ExpectedDefaultDisplay;
            try testing.expectEqual(display.raw(), default_display.raw());
            try testing.expectEqual(@as(i32, 200), display.width());
            try testing.expectEqual(@as(i32, 100), display.height());
            try testing.expectEqual(@as(i32, 220), display.physicalWidth());
            try testing.expectEqual(@as(i32, 140), display.physicalHeight());
            try testing.expectEqual(@as(i32, 7), display.offsetX());
            try testing.expectEqual(@as(i32, 9), display.offsetY());

            display.setRotation(.deg180);
            display.setDpi(123);
            try testing.expectEqual(Rotation.deg180, display.rotation());
            try testing.expectEqual(@as(i32, 123), display.dpi());
            try testing.expectEqual(display.activeScreen().raw(), fixture.screen().raw());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("lvgl/unit_tests/Display/raw_handle_roundtrip", testing_api.TestRunner.fromFn(lib, 1024 * 1024, Impl.raw_handle_roundtrip));
            t.run("lvgl/unit_tests/Display/runtime_properties_roundtrip_through_wrapper", testing_api.TestRunner.fromFn(lib, 1024 * 1024, Impl.runtime_properties_roundtrip_through_wrapper));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
