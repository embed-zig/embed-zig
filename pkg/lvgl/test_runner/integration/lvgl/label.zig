//! lvgl label test runner — label-specific smoke tests.
//!
//! Usage:
//!   const runner = @import("lvgl/test_runner/integration/lvgl/label.zig").make(std);

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
                fn labelTextAndLongMode() !void {
                    var fixture = try common.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var label = lvgl.Label.create(&screen) orelse return error.OutOfMemory;
                    var obj = label.asObj();
                    defer obj.delete();

                    label.setText("hello lvgl");
                    label.setLongMode(lvgl.Label.long_mode_scroll);

                    try test_lib.expectEqual(screen.raw(), obj.parent().?.raw());
                    try test_lib.expectEqualStrings("hello lvgl", mem.span(label.text()));
                    try test_lib.expectEqual(lvgl.Label.long_mode_scroll, label.longMode());
                }

                fn labelStaticTextStillUsesObjectApi() !void {
                    var fixture = try common.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var label = lvgl.Label.create(&screen) orelse return error.OutOfMemory;
                    var obj = label.asObj();
                    defer obj.delete();

                    label.setTextStatic("fixed");
                    obj.setPos(14, 9);
                    obj.updateLayout();

                    try test_lib.expectEqualStrings("fixed", mem.span(label.text()));
                    try test_lib.expectEqual(@as(i32, 14), obj.x());
                    try test_lib.expectEqual(@as(i32, 9), obj.y());
                }
            };

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
