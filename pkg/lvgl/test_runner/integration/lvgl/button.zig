//! lvgl button test runner — button/widget tree smoke tests.
//!
//! Usage:
//!   const runner = @import("lvgl/test_runner/integration/lvgl/button.zig").make(std);

const embed = @import("embed");
const testing = @import("testing");
const lvgl = @import("../../../../lvgl.zig");
const common = @import("common.zig");

pub fn make(comptime lib: type) testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const test_lib = lib.testing;
            const mem = lib.mem;

            const Cases = struct {
                fn buttonLabelTreeSmoke() !void {
                    var fixture = try common.Fixture.init();
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

                    try test_lib.expectEqual(screen.raw(), button_obj.parent().?.raw());
                    try test_lib.expectEqual(@as(u32, 1), screen.childCount());
                    try test_lib.expectEqual(@as(u32, 1), button_obj.childCount());
                    try test_lib.expectEqual(button_obj.raw(), label.asObj().parent().?.raw());
                    try test_lib.expectEqualStrings("hello lvgl", mem.span(label.text()));
                    try test_lib.expectEqual(@as(i32, 18), button_obj.x());
                    try test_lib.expectEqual(@as(i32, 12), button_obj.y());
                    try test_lib.expectEqual(@as(i32, 96), button_obj.width());
                    try test_lib.expectEqual(@as(i32, 40), button_obj.height());
                }

                fn buttonObjectApiSmoke() !void {
                    const Flags = lvgl.object.Flags;

                    var fixture = try common.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var button = lvgl.Button.create(&screen) orelse return error.OutOfMemory;
                    var obj = button.asObj();
                    defer obj.delete();

                    obj.setPos(21, 13);
                    obj.setSize(80, 32);
                    obj.addFlag(Flags.clickable);
                    obj.updateLayout();

                    try test_lib.expectEqual(@as(i32, 21), obj.x());
                    try test_lib.expectEqual(@as(i32, 13), obj.y());
                    try test_lib.expectEqual(@as(i32, 80), obj.width());
                    try test_lib.expectEqual(@as(i32, 32), obj.height());
                    try test_lib.expect(obj.hasFlag(Flags.clickable));
                }
            };

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

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing.TestRunner.make(Runner).new(runner);
}
