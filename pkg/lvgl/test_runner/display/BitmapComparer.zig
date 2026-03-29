const std = @import("std");
const Display = @import("../Display.zig");
const DrawArgs = @import("DrawArgs.zig");
const Comparer = @import("Comparer.zig");

pixels: []Display.Color565,

pub fn initOwned(pixels_arg: []Display.Color565) @This() {
    return .{ .pixels = pixels_arg };
}

pub fn comparer(self: *@This()) Comparer {
    return Comparer.from(@This(), self);
}

pub fn check(self: *@This(), draw: DrawArgs) Display.Error!bool {
    _ = draw.x;
    _ = draw.y;
    _ = draw.w;
    _ = draw.h;
    if (self.pixels.len != draw.pixels.len) return false;
    return std.mem.eql(Display.Color565, self.pixels, draw.pixels);
}
