//! Aggregates LVGL smoke and bitmap integration runners.

const display_api = @import("drivers");
const embed = @import("embed");
const testing = @import("testing");

const Display = display_api.Display;
const lvgl_mod = @import("integration/lvgl.zig");
const bitmap_mod = @import("integration/bitmap.zig");

pub fn make(comptime lib: type, output: ?*Display) testing.TestRunner {
    const Runner = struct {
        output: ?*Display,

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = allocator;

            t.run("lvgl", lvgl_mod.make(lib));
            t.run("bitmap", bitmap_mod.make(lib, self.output));

            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{ .output = output };
    return testing.TestRunner.make(Runner).new(runner);
}
