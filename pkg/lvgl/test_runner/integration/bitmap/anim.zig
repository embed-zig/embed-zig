const embed = @import("embed");
const display_api = @import("drivers");
const testing = @import("testing");
const Display = display_api.Display;
const Fixture = @import("test_utils/Fixture.zig");
const TestingDisplay = @import("test_utils/TestingDisplay.zig");
const CaptureFrameComparer = @import("test_utils/CaptureFrameComparer.zig");
const DeltaFrameComparer = @import("test_utils/DeltaFrameComparer.zig");
const lvgl = @import("../../../../lvgl.zig");
const Rgb = Display.Rgb;

const Tick = lvgl.Tick;
const Anim = lvgl.Anim;
const case_width_px: u16 = 64;
const case_height_px: u16 = 32;
const pixel_count = case_width_px * case_height_px;

pub const button_y: i32 = 10;
pub const button_w: i32 = 28;
pub const button_h: i32 = 14;
pub const button_start_x: i32 = 4;
pub const button_end_x: i32 = 24;

const AnimState = struct {
    obj: lvgl.Obj,
};

pub const Case = struct {
    pub const width_px = case_width_px;
    pub const height_px = case_height_px;

    baseline: [pixel_count]Rgb = undefined,
    blank_capture: CaptureFrameComparer = undefined,
    initial_capture: CaptureFrameComparer = undefined,
    moved_delta: DeltaFrameComparer = undefined,

    pub fn setup(self: *@This(), td: *TestingDisplay) !void {
        self.blank_capture = CaptureFrameComparer.init(case_width_px, case_height_px, self.baseline[0..], true);
        self.initial_capture = CaptureFrameComparer.init(case_width_px, case_height_px, self.baseline[0..], false);
        self.moved_delta = DeltaFrameComparer.init(
            case_width_px,
            case_height_px,
            self.baseline[0..],
            80,
            pixel_count * 3 / 4,
        );

        try td.addTestCaseResult(0, &.{}, self.blank_capture.comparer());
        try td.addTestCaseResult(1, &.{}, self.initial_capture.comparer());
        try td.addTestCaseResult(2, &.{}, self.moved_delta.comparer());
    }

    pub fn makeRunner(self: *@This(), comptime lib: type, display: *Display) testing.TestRunner {
        _ = self;
        return make(lib, display);
    }
};

pub fn make(comptime lib: type, display: *Display) testing.TestRunner {
    const Runner = struct {
        display: *Display,

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = allocator;
            const test_lib = lib.testing;

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

            button_obj.setPos(button_start_x, button_y);
            button_obj.setSize(button_w, button_h);
            button_obj.updateLayout();

            var label = button.createLabel() orelse {
                t.logFatal(@errorName(error.OutOfMemory));
                return false;
            };
            label.setText("GO");
            button_obj.updateLayout();

            fixture.render() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            var state = AnimState{ .obj = button_obj };
            var anim = Anim.init() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer anim.deinit();

            anim.setVar(&state);
            anim.setExecCb(animExecMoveButtonX);
            anim.setDuration(40);
            anim.setValues(button_start_x, button_end_x);
            anim.setRepeatCount(1);

            _ = anim.start();

            var i: u32 = 0;
            while (button_obj.x() < button_end_x and i < 32) : (i += 1) {
                Tick.inc(10);
                _ = Tick.timerHandler();
            }

            button_obj.updateLayout();
            test_lib.expectEqual(button_end_x, button_obj.x()) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
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

fn animExecMoveButtonX(var_: ?*anyopaque, value: i32) callconv(.c) void {
    const state: *AnimState = @ptrCast(@alignCast(var_.?));
    state.obj.setX(value);
}
