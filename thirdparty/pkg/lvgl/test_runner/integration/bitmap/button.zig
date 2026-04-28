const glib = @import("glib");
const embed = @import("embed");
const display_api = embed.drivers;
const Display = display_api.Display;
const Fixture = @import("test_utils/Fixture.zig");
const TestingDisplay = @import("test_utils/TestingDisplay.zig");
const CaptureFrameComparer = @import("test_utils/CaptureFrameComparer.zig");
const DeltaFrameComparer = @import("test_utils/DeltaFrameComparer.zig");
const lvgl = @import("../../../../lvgl.zig");
const Rgb = Display.Rgb;
const case_width_px: u16 = 64;
const case_height_px: u16 = 32;
const pixel_count = case_width_px * case_height_px;

pub const DrawSpec = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

pub const button_x: i32 = 8;
pub const button_y: i32 = 10;
pub const button_w: i32 = 28;
pub const button_h: i32 = 14;

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

    baseline: [pixel_count]Rgb = undefined,
    capture: CaptureFrameComparer = undefined,
    delta: DeltaFrameComparer = undefined,

    pub fn setup(self: *@This(), td: *TestingDisplay) !void {
        self.capture = CaptureFrameComparer.init(case_width_px, case_height_px, self.baseline[0..], true);
        self.delta = DeltaFrameComparer.init(
            case_width_px,
            case_height_px,
            self.baseline[0..],
            24,
            pixel_count / 2,
        );

        try td.addTestCaseResult(0, &.{}, self.capture.comparer());
        try td.addTestCaseResult(1, &.{}, self.delta.comparer());
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

            var screen = fixture.screen();
            var button = lvgl.Button.create(&screen) orelse {
                t.logFatal(@errorName(error.OutOfMemory));
                return false;
            };
            var button_obj = button.asObj();
            defer button_obj.delete();

            button_obj.setPos(button_x, button_y);
            button_obj.setSize(button_w, button_h);
            button_obj.updateLayout();

            var label = button.createLabel() orelse {
                t.logFatal(@errorName(error.OutOfMemory));
                return false;
            };
            label.setText("OK");
            button_obj.updateLayout();

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
