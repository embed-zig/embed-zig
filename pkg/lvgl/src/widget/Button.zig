const glib = @import("glib");
const binding = @import("../binding.zig");
const embed = @import("embed");
const Obj = @import("../object/Obj.zig");
const Flags = @import("../object/Flags.zig");
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
            const mem = grt.std.mem;

            const Cases = struct {
                fn composesObjectLayerAndCanHostChildLabel() !void {
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var button = Self.create(&screen) orelse return error.OutOfMemory;
                    var button_obj = button.asObj();
                    defer button_obj.delete();

                    var label = button.createLabel() orelse return error.OutOfMemory;
                    label.setText("press");

                    try grt.std.testing.expectEqual(screen.raw(), button_obj.parent().?.raw());
                    try grt.std.testing.expectEqual(@as(u32, 1), button_obj.childCount());
                    try grt.std.testing.expectEqual(button_obj.raw(), label.asObj().parent().?.raw());
                    try grt.std.testing.expectEqualStrings("press", mem.span(label.text()));
                }

                fn objectApiRemainsTheSourceOfGenericBehavior() !void {
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

                    try grt.std.testing.expectEqual(@as(i32, 21), obj.x());
                    try grt.std.testing.expectEqual(@as(i32, 13), obj.y());
                    try grt.std.testing.expectEqual(@as(i32, 80), obj.width());
                    try grt.std.testing.expectEqual(@as(i32, 32), obj.height());
                    try grt.std.testing.expect(obj.hasFlag(Flags.clickable));
                }

                fn rawAndObjectRoundtripPreserveHandle() !void {
                    const raw_handle: *binding.Obj = @ptrFromInt(1);
                    const button = Self.fromRaw(raw_handle);

                    try grt.std.testing.expectEqual(raw_handle, button.raw());
                    try grt.std.testing.expectEqual(raw_handle, button.asObj().raw());
                }
            };

            Cases.composesObjectLayerAndCanHostChildLabel() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.objectApiRemainsTheSourceOfGenericBehavior() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.rawAndObjectRoundtripPreserveHandle() catch |err| {
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
