const glib = @import("glib");
const binding = @import("../binding.zig");
const embed = @import("embed");

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

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const lvgl_testing = @import("../testing.zig");
            const Obj = @import("Obj.zig");

            const Cases = struct {
                fn rawHelpersTrackParentAndChildOrdering() !void {
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var parent = Obj.create(&screen) orelse return error.OutOfMemory;
                    defer parent.delete();

                    _ = Obj.create(&parent) orelse return error.OutOfMemory;
                    const second = Obj.create(&parent) orelse return error.OutOfMemory;

                    try grt.std.testing.expectEqual(@as(u32, 2), childCount(parent.raw()));
                    try grt.std.testing.expectEqual(parent.raw(), parentRaw(second.raw()).?);
                    try grt.std.testing.expectEqual(second.raw(), childRaw(parent.raw(), -1).?);
                    try grt.std.testing.expectEqual(screen.raw(), screenRaw(second.raw()).?);
                }
            };

            Cases.rawHelpersTrackParentAndChildOrdering() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            grt.std.testing.allocator.destroy(self);
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return glib.testing.TestRunner.make(Runner).new(runner);
}
