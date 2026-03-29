const Display = @import("../Display.zig");
const DrawArgs = @import("DrawArgs.zig");
const Comparer = @import("Comparer.zig");

width_px: u16,
height_px: u16,

pub fn init(width_px: u16, height_px: u16) @This() {
    return .{
        .width_px = width_px,
        .height_px = height_px,
    };
}

pub fn comparer(self: *@This()) Comparer {
    return Comparer.from(@This(), self);
}

pub fn check(self: *@This(), draw: DrawArgs) Display.Error!bool {
    if (draw.x != 0 or draw.y != 0 or draw.w != self.width_px or draw.h != self.height_px) {
        return error.DrawAreaMismatch;
    }
    return draw.pixels.len == @as(usize, self.width_px) * @as(usize, self.height_px);
}
