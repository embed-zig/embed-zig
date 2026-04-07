//! Aggregates LVGL smoke and bitmap integration runners.

const embed = @import("embed");
const testing = @import("testing");

const lvgl_mod = @import("integration/lvgl.zig");
const bitmap_mod = @import("integration/bitmap.zig");

pub fn make(comptime lib: type) testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("lvgl", lvgl_mod.make(lib));
            t.run("bitmap", bitmap_mod.make(lib));

            return t.wait();
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
