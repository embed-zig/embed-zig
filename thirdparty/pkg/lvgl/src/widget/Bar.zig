const glib = @import("glib");
const binding = @import("../binding.zig");
const Obj = @import("../object/Obj.zig");

const Self = @This();

handle: *binding.Obj,

pub fn fromRaw(handle: *binding.Obj) Self {
    return .{ .handle = handle };
}

pub fn fromObj(obj: Obj) Self {
    return fromRaw(obj.raw());
}

pub fn create(parent_obj: *const Obj) ?Self {
    const handle = binding.lv_bar_create(parent_obj.raw()) orelse return null;
    return fromRaw(handle);
}

pub fn raw(self: *const Self) *binding.Obj {
    return self.handle;
}

pub fn asObj(self: *const Self) Obj {
    return Obj.fromRaw(self.handle);
}

pub fn setRange(self: *const Self, min: i32, max: i32) void {
    binding.lv_bar_set_range(self.handle, min, max);
}

pub fn setValue(self: *const Self, value: i32, animated: bool) void {
    binding.lv_bar_set_value(self.handle, value, animated);
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

            const Cases = struct {
                fn composesObjectLayerAndSetsValue() !void {
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var bar = Self.create(&screen) orelse return error.OutOfMemory;
                    var obj = bar.asObj();
                    defer obj.delete();

                    bar.setRange(0, 255);
                    bar.setValue(128, false);

                    try grt.std.testing.expectEqual(screen.raw(), obj.parent().?.raw());
                }
            };

            Cases.composesObjectLayerAndSetsValue() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
