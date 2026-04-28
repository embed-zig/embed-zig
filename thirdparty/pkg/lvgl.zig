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
