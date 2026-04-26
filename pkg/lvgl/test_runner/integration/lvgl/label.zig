//! lvgl label test runner — label-specific smoke tests.
//!
//! Usage:
//!   const runner = @import("lvgl/test_runner/integration/lvgl/label.zig").make(std);

const embed = @import("embed");
const testing = @import("testing");
const lvgl = @import("../../../../lvgl.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            const Cases = struct {
                fn labelTextAndLongMode() !void {
                    var fixture = try test_utils.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var label = lvgl.Label.create(&screen) orelse return error.OutOfMemory;
                    var obj = label.asObj();
                    defer obj.delete();

                    label.setText("hello lvgl");
                    label.setLongMode(lvgl.Label.long_mode_scroll);

                    try lib.testing.expectEqual(screen.raw(), obj.parent().?.raw());
                    try lib.testing.expectEqualStrings("hello lvgl", lib.mem.span(label.text()));
                    try lib.testing.expectEqual(lvgl.Label.long_mode_scroll, label.longMode());
                }

                fn labelStaticTextStillUsesObjectApi() !void {
                    var fixture = try test_utils.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var label = lvgl.Label.create(&screen) orelse return error.OutOfMemory;
                    var obj = label.asObj();
                    defer obj.delete();

                    label.setTextStatic("fixed");
                    obj.setPos(14, 9);
                    obj.updateLayout();

                    try lib.testing.expectEqualStrings("fixed", lib.mem.span(label.text()));
                    try lib.testing.expectEqual(@as(i32, 14), obj.x());
                    try lib.testing.expectEqual(@as(i32, 9), obj.y());
                }
            };

            _ = allocator;

            Cases.labelTextAndLongMode() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.labelStaticTextStillUsesObjectApi() catch |err| {
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
