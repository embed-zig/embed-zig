const std = @import("std");
const embed = @import("embed");
const testing_mod = @import("testing");
const bitmap = @import("../test_runner/bitmap.zig");
const Display = @import("../test_runner/Display.zig");
const TestingDisplay = @import("../test_runner/display/TestingDisplay.zig");
const Fixture = @import("../test_runner/display/Fixture.zig");
const FullFrameComparer = @import("../test_runner/display/FullFrameComparer.zig");
const CaptureFrameComparer = @import("../test_runner/display/CaptureFrameComparer.zig");
const DeltaFrameComparer = @import("../test_runner/display/DeltaFrameComparer.zig");

const Color565 = Display.Color565;
const pixel_count = Fixture.width * Fixture.height;

test "lvgl/integration_tests/bitmap" {
    var t = testing_mod.T.new(std, .lvgl_integration_bitmap);
    defer t.deinit();

    t.run("bitmap/basic", BitmapCaseRunner.make(BasicCase, .{}));
    t.run("bitmap/label", BitmapCaseRunner.make(LabelCase, .{}));
    t.run("bitmap/button", BitmapCaseRunner.make(ButtonCase, .{}));
    t.run("bitmap/anim", BitmapCaseRunner.make(AnimCase, .{}));
    t.run("bitmap", BitmapCaseRunner.make(SuiteCase, .{}));

    if (!t.wait()) return error.TestFailed;
}

const BitmapCaseRunner = struct {
    fn make(comptime Case: type, case_data: Case) testing_mod.TestRunner {
        const Runner = struct {
            case_data: Case,
            td: TestingDisplay = undefined,
            display: Display = undefined,
            is_initialized: bool = false,

            pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
                self.td = TestingDisplay.init(allocator, Fixture.width, Fixture.height);
                errdefer self.td.deinit();

                try self.case_data.setup(&self.td);
                self.display = self.td.display();
                self.is_initialized = true;
            }

            pub fn run(self: *@This(), child_t: *testing_mod.T, allocator: std.mem.Allocator) bool {
                var runner = self.case_data.makeRunner(&self.display);
                defer runner.deinit(allocator);

                if (!runner.run(child_t, allocator)) return false;

                self.td.assertComplete() catch |err| {
                    child_t.logFatal(@errorName(err));
                    return false;
                };
                return true;
            }

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                _ = allocator;
                if (self.is_initialized) {
                    self.td.deinit();
                }
                std.testing.allocator.destroy(self);
            }
        };

        const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
        runner.* = .{ .case_data = case_data };
        return testing_mod.TestRunner.make(Runner).new(runner);
    }
};

const BasicCase = struct {
    blank: FullFrameComparer = undefined,

    pub fn setup(self: *@This(), td: *TestingDisplay) !void {
        self.blank = FullFrameComparer.init(Fixture.width, Fixture.height);
        try td.addTestCaseResult(0, &[_]Color565{}, self.blank.comparer());
    }

    pub fn makeRunner(self: *@This(), display: *Display) testing_mod.TestRunner {
        _ = self;
        return bitmap.basic.make(std, display);
    }
};

const LabelCase = struct {
    baseline: [pixel_count]Color565 = undefined,
    capture: CaptureFrameComparer = undefined,
    delta: DeltaFrameComparer = undefined,

    pub fn setup(self: *@This(), td: *TestingDisplay) !void {
        self.capture = CaptureFrameComparer.init(Fixture.width, Fixture.height, self.baseline[0..], true);
        self.delta = DeltaFrameComparer.init(
            Fixture.width,
            Fixture.height,
            self.baseline[0..],
            4,
            pixel_count / 3,
        );

        try td.addTestCaseResult(0, &[_]Color565{}, self.capture.comparer());
        try td.addTestCaseResult(1, &[_]Color565{}, self.delta.comparer());
    }

    pub fn makeRunner(self: *@This(), display: *Display) testing_mod.TestRunner {
        _ = self;
        return bitmap.label.make(std, display);
    }
};

const ButtonCase = struct {
    baseline: [pixel_count]Color565 = undefined,
    capture: CaptureFrameComparer = undefined,
    delta: DeltaFrameComparer = undefined,

    pub fn setup(self: *@This(), td: *TestingDisplay) !void {
        self.capture = CaptureFrameComparer.init(Fixture.width, Fixture.height, self.baseline[0..], true);
        self.delta = DeltaFrameComparer.init(
            Fixture.width,
            Fixture.height,
            self.baseline[0..],
            24,
            pixel_count / 2,
        );

        try td.addTestCaseResult(0, &[_]Color565{}, self.capture.comparer());
        try td.addTestCaseResult(1, &[_]Color565{}, self.delta.comparer());
    }

    pub fn makeRunner(self: *@This(), display: *Display) testing_mod.TestRunner {
        _ = self;
        return bitmap.button.make(std, display);
    }
};

const AnimCase = struct {
    baseline: [pixel_count]Color565 = undefined,
    blank_capture: CaptureFrameComparer = undefined,
    initial_capture: CaptureFrameComparer = undefined,
    moved_delta: DeltaFrameComparer = undefined,

    pub fn setup(self: *@This(), td: *TestingDisplay) !void {
        self.blank_capture = CaptureFrameComparer.init(Fixture.width, Fixture.height, self.baseline[0..], true);
        self.initial_capture = CaptureFrameComparer.init(Fixture.width, Fixture.height, self.baseline[0..], false);
        self.moved_delta = DeltaFrameComparer.init(
            Fixture.width,
            Fixture.height,
            self.baseline[0..],
            80,
            pixel_count * 3 / 4,
        );

        try td.addTestCaseResult(0, &[_]Color565{}, self.blank_capture.comparer());
        try td.addTestCaseResult(1, &[_]Color565{}, self.initial_capture.comparer());
        try td.addTestCaseResult(2, &[_]Color565{}, self.moved_delta.comparer());
    }

    pub fn makeRunner(self: *@This(), display: *Display) testing_mod.TestRunner {
        _ = self;
        return bitmap.anim.make(std, display);
    }
};

const SuiteCase = struct {
    label_baseline: [pixel_count]Color565 = undefined,
    button_baseline: [pixel_count]Color565 = undefined,
    anim_initial: [pixel_count]Color565 = undefined,
    blank: FullFrameComparer = undefined,
    label_capture: CaptureFrameComparer = undefined,
    label_delta: DeltaFrameComparer = undefined,
    button_capture: CaptureFrameComparer = undefined,
    button_delta: DeltaFrameComparer = undefined,
    anim_blank: CaptureFrameComparer = undefined,
    anim_capture: CaptureFrameComparer = undefined,
    anim_delta: DeltaFrameComparer = undefined,

    pub fn setup(self: *@This(), td: *TestingDisplay) !void {
        self.blank = FullFrameComparer.init(Fixture.width, Fixture.height);
        self.label_capture = CaptureFrameComparer.init(Fixture.width, Fixture.height, self.label_baseline[0..], true);
        self.label_delta = DeltaFrameComparer.init(
            Fixture.width,
            Fixture.height,
            self.label_baseline[0..],
            4,
            pixel_count / 3,
        );
        self.button_capture = CaptureFrameComparer.init(Fixture.width, Fixture.height, self.button_baseline[0..], true);
        self.button_delta = DeltaFrameComparer.init(
            Fixture.width,
            Fixture.height,
            self.button_baseline[0..],
            24,
            pixel_count / 2,
        );
        self.anim_blank = CaptureFrameComparer.init(Fixture.width, Fixture.height, self.anim_initial[0..], true);
        self.anim_capture = CaptureFrameComparer.init(Fixture.width, Fixture.height, self.anim_initial[0..], false);
        self.anim_delta = DeltaFrameComparer.init(
            Fixture.width,
            Fixture.height,
            self.anim_initial[0..],
            80,
            pixel_count * 3 / 4,
        );

        try td.addTestCaseResult(0, &[_]Color565{}, self.blank.comparer());
        try td.addTestCaseResult(1, &[_]Color565{}, self.label_capture.comparer());
        try td.addTestCaseResult(2, &[_]Color565{}, self.label_delta.comparer());
        try td.addTestCaseResult(3, &[_]Color565{}, self.button_capture.comparer());
        try td.addTestCaseResult(4, &[_]Color565{}, self.button_delta.comparer());
        try td.addTestCaseResult(5, &[_]Color565{}, self.anim_blank.comparer());
        try td.addTestCaseResult(6, &[_]Color565{}, self.anim_capture.comparer());
        try td.addTestCaseResult(7, &[_]Color565{}, self.anim_delta.comparer());
    }

    pub fn makeRunner(self: *@This(), display: *Display) testing_mod.TestRunner {
        _ = self;
        return bitmap.make(std, display);
    }
};
