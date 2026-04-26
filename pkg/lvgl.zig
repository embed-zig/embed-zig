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
    pub const unit = @import("lvgl/test_runner/unit.zig");
    pub const integration = @import("lvgl/test_runner/integration.zig");
};

/// Bitmap harness display for `test_runner.integration.make(lib, &display)`.
pub const IntegrationTestingDisplay = @import("lvgl/test_runner/integration/bitmap/test_utils/TestingDisplay.zig");

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
    const std = @import("std");
    const testing_mod = @import("testing");

    var t = testing_mod.T.new(std, .lvgl_unit);
    defer t.deinit();

    t.run("unit", test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "lvgl/integration_tests" {
    const std = @import("std");
    const testing_mod = @import("testing");
    std.testing.log_level = .info;

    var t = testing_mod.T.new(std, .lvgl_integration);
    defer t.deinit();

    var testing_display = IntegrationTestingDisplay.initPassthrough(std.testing.allocator, 320, 240, null);
    defer testing_display.deinit();

    var harness_display = try testing_display.display();
    defer harness_display.deinit();

    t.run("integration", test_runner.integration.make(std, &harness_display));
    if (!t.wait()) return error.TestFailed;
    try testing_display.assertComplete();
}
