const lvgl = @import("lvgl");

pub const selector_main = lvgl.binding.LV_PART_MAIN;
pub const selector_indicator = lvgl.binding.LV_PART_INDICATOR;
pub const selector_pressed = lvgl.binding.LV_PART_MAIN | lvgl.binding.LV_STATE_PRESSED;

pub const bg = lvgl.Color.fromHex(0x202A4E);
pub const panel = lvgl.Color.fromHex(0xF8FAFF);
pub const accent = lvgl.Color.fromHex(0x6973FF);
pub const accent_pressed = lvgl.Color.fromHex(0x4F5DFF);
pub const text = lvgl.Color.fromHex(0x101830);
pub const muted = lvgl.Color.fromHex(0x76809E);
pub const control = lvgl.Color.fromHex(0xE0E6F6);
pub const control_pressed = lvgl.Color.fromHex(0xCAD4F0);
pub const mic_active = lvgl.Color.fromHex(0x35C77B);
pub const mic_active_pressed = lvgl.Color.fromHex(0x259864);
pub const meter = lvgl.Color.fromHex(0xD2D8E8);
