//! Bitmap suite runner — aggregated per-display bitmap cases (shared by integration).

const embed = @import("embed");
const display_api = @import("drivers");
const testing = @import("testing");

pub const Display = display_api.Display;
pub const Rgb = Display.Rgb;
pub const rgb = Display.rgb;
pub const TestingDisplay = @import("test_utils/TestingDisplay.zig");
pub const Fixture = @import("test_utils/Fixture.zig");
pub const basic = @import("basic.zig");
pub const label = @import("label.zig");
pub const button = @import("button.zig");
pub const anim = @import("anim.zig");

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
