const display_api = @import("embed").drivers;
const display_error = @import("Error.zig");
const DrawArgs = @import("DrawArgs.zig");
const Comparer = @import("Comparer.zig");

width_px: u16,
height_px: u16,
baseline: []const display_api.Display.Rgb,
min_changed: usize,
max_changed: usize,

pub fn init(
    width_px: u16,
    height_px: u16,
    baseline: []const display_api.Display.Rgb,
    min_changed: usize,
    max_changed: usize,
) @This() {
    return .{
        .width_px = width_px,
        .height_px = height_px,
        .baseline = baseline,
        .min_changed = min_changed,
        .max_changed = max_changed,
    };
}

pub fn comparer(self: *@This()) Comparer {
    return Comparer.from(@This(), self);
}

pub fn check(self: *@This(), draw: DrawArgs) display_error.Error!bool {
    if (draw.x != 0 or draw.y != 0 or draw.w != self.width_px or draw.h != self.height_px) {
        return error.DrawAreaMismatch;
    }
    if (draw.pixels.len != self.baseline.len) return false;

    var changed: usize = 0;
    for (draw.pixels, self.baseline) |actual, before| {
        if (!actual.cmp(before)) changed += 1;
    }
    return changed >= self.min_changed and changed <= self.max_changed;
}
