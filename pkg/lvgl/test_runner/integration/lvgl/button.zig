//! lvgl button test runner — button/widget tree smoke tests.
//!
//! Usage:
//!   const runner = @import("lvgl/test_runner/integration/lvgl/button.zig").make(gstd.runtime);

const glib = @import("glib");
const embed = @import("embed");
const lvgl = @import("../../../../lvgl.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            const Cases = struct {
                fn buttonLabelTreeSmoke() !void {
                    var fixture = try test_utils.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var button = lvgl.Button.create(&screen) orelse return error.OutOfMemory;
                    var button_obj = button.asObj();
                    defer button_obj.delete();

                    button_obj.setPos(18, 12);
                    button_obj.setSize(96, 40);
                    button_obj.updateLayout();

                    var label = button.createLabel() orelse return error.OutOfMemory;
                    label.setText("hello lvgl");

                    try grt.std.testing.expectEqual(screen.raw(), button_obj.parent().?.raw());
                    try grt.std.testing.expectEqual(@as(u32, 1), screen.childCount());
                    try grt.std.testing.expectEqual(@as(u32, 1), button_obj.childCount());
                    try grt.std.testing.expectEqual(button_obj.raw(), label.asObj().parent().?.raw());
                    try grt.std.testing.expectEqualStrings("hello lvgl", grt.std.mem.span(label.text()));
                    try grt.std.testing.expectEqual(@as(i32, 18), button_obj.x());
                    try grt.std.testing.expectEqual(@as(i32, 12), button_obj.y());
                    try grt.std.testing.expectEqual(@as(i32, 96), button_obj.width());
                    try grt.std.testing.expectEqual(@as(i32, 40), button_obj.height());
                }

                fn buttonObjectApiSmoke() !void {
                    const Flags = lvgl.object.Flags;

                    var fixture = try test_utils.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var button = lvgl.Button.create(&screen) orelse return error.OutOfMemory;
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
            };

            _ = allocator;

            Cases.buttonLabelTreeSmoke() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.buttonObjectApiSmoke() catch |err| {
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
