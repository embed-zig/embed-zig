const binding = @import("../binding.zig");
const embed = @import("embed");
const testing_api = @import("testing");

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

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const lvgl_testing = @import("../testing.zig");
            const Obj = @import("Obj.zig");

            const Cases = struct {
                fn rawHelpersTrackParentAndChildOrdering() !void {
                    const testing = lib.testing;
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
            };

            Cases.rawHelpersTrackParentAndChildOrdering() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
