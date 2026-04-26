const glib = @import("glib");
const embed = @import("embed");
const display_api = @import("drivers");
const Display = display_api.Display;
const Fixture = @import("test_utils/Fixture.zig");
const TestingDisplay = @import("test_utils/TestingDisplay.zig");
const FullFrameComparer = @import("test_utils/FullFrameComparer.zig");

pub const DrawSpec = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

const case_width_px: u16 = 64;
const case_height_px: u16 = 32;

pub fn drawSpec(display: *const Display) DrawSpec {
    return .{
        .x = 0,
        .y = 0,
        .w = display.width(),
        .h = display.height(),
    };
}

pub const Case = struct {
    pub const width_px = case_width_px;
    pub const height_px = case_height_px;

    blank: FullFrameComparer = undefined,

    pub fn setup(self: *@This(), td: *TestingDisplay) !void {
        self.blank = FullFrameComparer.init(case_width_px, case_height_px);
        try td.addTestCaseResult(0, &.{}, self.blank.comparer());
    }

    pub fn makeRunner(self: *@This(), comptime grt: type, display: *Display) glib.testing.TestRunner {
        _ = self;
        return make(grt, display);
    }
};

pub fn make(comptime grt: type, display: *Display) glib.testing.TestRunner {
    const Runner = struct {
        display: *Display,

        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
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

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            grt.std.testing.allocator.destroy(self);
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{
        .display = display,
    };
    return glib.testing.TestRunner.make(Runner).new(runner);
}
