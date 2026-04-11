const embed = @import("embed");
const display_api = @import("drivers");
const testing = @import("testing");
const Display = display_api.Display;
const Fixture = @import("test_utils/Fixture.zig");

pub const DrawSpec = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

pub fn drawSpec(display: *const Display) DrawSpec {
    return .{
        .x = 0,
        .y = 0,
        .w = display.width(),
        .h = display.height(),
    };
}

pub fn make(comptime lib: type, display: *Display) testing.TestRunner {
    const Runner = struct {
        display: *Display,

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = allocator;
            var fixture = Fixture.init(self.display) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer fixture.deinit();
            fixture.render() catch |err| {
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
    runner.* = .{
        .display = display,
    };
    return testing.TestRunner.make(Runner).new(runner);
}
