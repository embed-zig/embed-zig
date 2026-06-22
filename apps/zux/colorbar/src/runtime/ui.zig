const lvgl_mod = @import("ui/Lvgl.zig");

pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    return lvgl_mod.make(grt, ZuxAppType);
}
