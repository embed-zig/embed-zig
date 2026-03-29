//! lvgl — LVGL bindings.
//!
//! Usage:
//!   const lvgl = @import("lvgl");
//!   const lvgl_osal = @import("lvgl_osal");
//!   _ = lvgl.binding;

pub const binding = @import("lvgl/src/binding.zig");
const types_mod = @import("lvgl/src/types.zig");

pub const types = types_mod;
pub const Result = types_mod.Result;
pub const StyleRes = types_mod.StyleRes;
pub const Align = types_mod.Align;
pub const Dir = types_mod.Dir;
pub const Opa = types_mod.Opa;
pub const opa = types_mod.opa;

pub const Color = @import("lvgl/src/Color.zig");
pub const Point = @import("lvgl/src/Point.zig");
pub const Area = @import("lvgl/src/Area.zig");
pub const Style = @import("lvgl/src/Style.zig");
pub const Display = @import("lvgl/src/Display.zig");
pub const Indev = @import("lvgl/src/Indev.zig");
pub const Tick = @import("lvgl/src/Tick.zig");
pub const Event = @import("lvgl/src/Event.zig");
pub const Anim = @import("lvgl/src/Anim.zig");
pub const Subject = @import("lvgl/src/Subject.zig");
pub const Observer = @import("lvgl/src/Observer.zig");
pub const object = @import("lvgl/src/object.zig");
pub const Obj = object.Obj;
pub const widget = @import("lvgl/src/widget.zig");
pub const Label = widget.Label;
pub const Button = widget.Button;
pub const test_runner = struct {
    pub const Display = @import("lvgl/test_runner/Display.zig");
    pub const lvgl = @import("lvgl/test_runner/lvgl.zig");
    pub const bitmap = @import("lvgl/test_runner/bitmap.zig");
};

pub fn init() void {
    binding.lv_init();
}

pub fn deinit() void {
    binding.lv_deinit();
}

pub fn isInitialized() bool {
    return binding.lv_is_initialized();
}

test "lvgl/unit_tests" {
    _ = @import("lvgl/src/binding.zig");
    _ = @import("lvgl/src/types.zig");
    _ = @import("lvgl/src/Color.zig");
    _ = @import("lvgl/src/Point.zig");
    _ = @import("lvgl/src/Area.zig");
    _ = @import("lvgl/src/Style.zig");
    _ = @import("lvgl/src/Display.zig");
    _ = @import("lvgl/src/Indev.zig");
    _ = @import("lvgl/src/Tick.zig");
    _ = @import("lvgl/src/Event.zig");
    _ = @import("lvgl/src/Anim.zig");
    _ = @import("lvgl/src/Subject.zig");
    _ = @import("lvgl/src/Observer.zig");
    _ = @import("lvgl/src/object.zig");
    _ = @import("lvgl/src/object/Obj.zig");
    _ = @import("lvgl/src/object/Tree.zig");
    _ = @import("lvgl/src/object/Flags.zig");
    _ = @import("lvgl/src/object/State.zig");
    _ = @import("lvgl/src/widget.zig");
    _ = @import("lvgl/src/widget/Label.zig");
    _ = @import("lvgl/src/widget/Button.zig");
    _ = @import("lvgl/test_runner/Display.zig");
    _ = @import("lvgl/test_runner/display/DrawArgs.zig");
    _ = @import("lvgl/test_runner/display/Comparer.zig");
    _ = @import("lvgl/test_runner/display/BitmapComparer.zig");
    _ = @import("lvgl/test_runner/display/FullFrameComparer.zig");
    _ = @import("lvgl/test_runner/display/CaptureFrameComparer.zig");
    _ = @import("lvgl/test_runner/display/DeltaFrameComparer.zig");
    _ = @import("lvgl/test_runner/display/PipeComparer.zig");
    _ = @import("lvgl/test_runner/display/Fixture.zig");
    _ = @import("lvgl/test_runner/display/TestingDisplay.zig");
    _ = @import("lvgl/test_runner/bitmap/basic.zig");
    _ = @import("lvgl/test_runner/bitmap/label.zig");
    _ = @import("lvgl/test_runner/bitmap/button.zig");
    _ = @import("lvgl/test_runner/bitmap/anim.zig");
    _ = @import("lvgl/test_runner/bitmap.zig");
    _ = @import("lvgl/integration_test/bitmap.zig");
    _ = @import("lvgl/integration_test/lvgl.zig");
    _ = @import("lvgl/test_runner/lvgl/common.zig");
    _ = @import("lvgl/test_runner/lvgl/anim.zig");
    _ = @import("lvgl/test_runner/lvgl/basic.zig");
    _ = @import("lvgl/test_runner/lvgl/label.zig");
    _ = @import("lvgl/test_runner/lvgl/button.zig");
    _ = @import("lvgl/test_runner/lvgl/os.zig");
    _ = @import("lvgl/test_runner/lvgl.zig");
}

test "lvgl/integration_tests" {
    const std = @import("std");
    std.testing.log_level = .info;

    _ = @import("lvgl/integration_test/lvgl.zig");
    _ = @import("lvgl/integration_test/bitmap.zig");
}
