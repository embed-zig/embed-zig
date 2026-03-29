const Display = @import("../Display.zig");
const DrawArgs = @import("DrawArgs.zig");
const Comparer = @import("Comparer.zig");

width_px: u16,
height_px: u16,
capture: []Display.Color565,
require_uniform: bool = false,

pub fn init(width_px: u16, height_px: u16, capture: []Display.Color565, require_uniform: bool) @This() {
    return .{
        .width_px = width_px,
        .height_px = height_px,
        .capture = capture,
        .require_uniform = require_uniform,
    };
}

pub fn comparer(self: *@This()) Comparer {
    return Comparer.from(@This(), self);
}

pub fn check(self: *@This(), draw: DrawArgs) Display.Error!bool {
    if (draw.x != 0 or draw.y != 0 or draw.w != self.width_px or draw.h != self.height_px) {
        return error.DrawAreaMismatch;
    }
    if (draw.pixels.len != self.capture.len) return false;
    @memcpy(self.capture, draw.pixels);

    if (!self.require_uniform) return true;

    for (draw.pixels[1..]) |pixel| {
        if (pixel != draw.pixels[0]) return false;
    }
    return true;
}
