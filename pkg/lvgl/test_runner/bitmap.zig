//! lvgl bitmap test runner — verifies rendered bitmap output.
//!
//! Usage:
//!   var td = lvgl.test_runner.bitmap.TestingDisplay.init(...);
//!   var display = td.display();
//!   const runner = lvgl.test_runner.bitmap.make(std, &display);

const embed = @import("embed");
const testing = @import("testing");

pub const Display = @import("Display.zig");
pub const Color565 = Display.Color565;
pub const rgb565 = Display.rgb565;
pub const TestingDisplay = @import("display/TestingDisplay.zig");
pub const Fixture = @import("display/Fixture.zig");
pub const basic = @import("bitmap/basic.zig");
pub const label = @import("bitmap/label.zig");
pub const button = @import("bitmap/button.zig");
pub const anim = @import("bitmap/anim.zig");

pub fn make(comptime lib: type, display: *Display) testing.TestRunner {
    const Runner = struct {
        display: *Display,

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = allocator;
            t.run("basic", basic.make(lib, self.display));
            t.run("label", label.make(lib, self.display));
            t.run("button", button.make(lib, self.display));
            t.run("anim", anim.make(lib, self.display));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{
        .display = display,
    };
    return testing.TestRunner.make(Runner).new(runner);
}
