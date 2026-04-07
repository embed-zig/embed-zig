const display_api = @import("display");
const testing_mod = @import("testing");
const TestingDisplay = @import("TestingDisplay.zig");
const Fixture = @import("Fixture.zig");
const FullFrameComparer = @import("FullFrameComparer.zig");
const CaptureFrameComparer = @import("CaptureFrameComparer.zig");
const DeltaFrameComparer = @import("DeltaFrameComparer.zig");
const suite = @import("../suite.zig");

const Display = display_api.Display;
const Rgb = Display.Rgb;

pub const pixel_count = Fixture.width * Fixture.height;

pub const BasicCase = struct {
    blank: FullFrameComparer = undefined,

    pub fn setup(self: *@This(), td: *TestingDisplay) !void {
        self.blank = FullFrameComparer.init(Fixture.width, Fixture.height);
        try td.addTestCaseResult(0, &[_]Rgb{}, self.blank.comparer());
    }

    pub fn makeRunner(self: *@This(), comptime L: type, display: *Display) testing_mod.TestRunner {
        _ = self;
        return suite.basic.make(L, display);
    }
};

pub const LabelCase = struct {
    baseline: [pixel_count]Rgb = undefined,
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

        try td.addTestCaseResult(0, &[_]Rgb{}, self.capture.comparer());
        try td.addTestCaseResult(1, &[_]Rgb{}, self.delta.comparer());
    }

    pub fn makeRunner(self: *@This(), comptime L: type, display: *Display) testing_mod.TestRunner {
        _ = self;
        return suite.label.make(L, display);
    }
};

pub const ButtonCase = struct {
    baseline: [pixel_count]Rgb = undefined,
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

        try td.addTestCaseResult(0, &[_]Rgb{}, self.capture.comparer());
        try td.addTestCaseResult(1, &[_]Rgb{}, self.delta.comparer());
    }

    pub fn makeRunner(self: *@This(), comptime L: type, display: *Display) testing_mod.TestRunner {
        _ = self;
        return suite.button.make(L, display);
    }
};

pub const AnimCase = struct {
    baseline: [pixel_count]Rgb = undefined,
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

        try td.addTestCaseResult(0, &[_]Rgb{}, self.blank_capture.comparer());
        try td.addTestCaseResult(1, &[_]Rgb{}, self.initial_capture.comparer());
        try td.addTestCaseResult(2, &[_]Rgb{}, self.moved_delta.comparer());
    }

    pub fn makeRunner(self: *@This(), comptime L: type, display: *Display) testing_mod.TestRunner {
        _ = self;
        return suite.anim.make(L, display);
    }
};

pub const SuiteCase = struct {
    label_baseline: [pixel_count]Rgb = undefined,
    button_baseline: [pixel_count]Rgb = undefined,
    anim_initial: [pixel_count]Rgb = undefined,
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

        try td.addTestCaseResult(0, &[_]Rgb{}, self.blank.comparer());
        try td.addTestCaseResult(1, &[_]Rgb{}, self.label_capture.comparer());
        try td.addTestCaseResult(2, &[_]Rgb{}, self.label_delta.comparer());
        try td.addTestCaseResult(3, &[_]Rgb{}, self.button_capture.comparer());
        try td.addTestCaseResult(4, &[_]Rgb{}, self.button_delta.comparer());
        try td.addTestCaseResult(5, &[_]Rgb{}, self.anim_blank.comparer());
        try td.addTestCaseResult(6, &[_]Rgb{}, self.anim_capture.comparer());
        try td.addTestCaseResult(7, &[_]Rgb{}, self.anim_delta.comparer());
    }

    pub fn makeRunner(self: *@This(), comptime L: type, display: *Display) testing_mod.TestRunner {
        _ = self;
        return suite.make(L, display);
    }
};
