//! Aggregates LVGL smoke and bitmap integration runners.

const glib = @import("glib");
const display_api = @import("drivers");
const embed = @import("embed");

const Display = display_api.Display;
const lvgl_mod = @import("integration/lvgl.zig");
const bitmap_mod = @import("integration/bitmap.zig");

pub fn make(comptime grt: type, output: ?*Display) glib.testing.TestRunner {
    const Runner = struct {
        output: ?*Display,

        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = allocator;

            t.run("lvgl", lvgl_mod.make(grt));
            t.run("bitmap", bitmap_mod.make(grt, self.output));

            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            grt.std.testing.allocator.destroy(self);
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{ .output = output };
    return glib.testing.TestRunner.make(Runner).new(runner);
}
