const std = @import("std");
const display_api = @import("display");
const display_error = @import("Error.zig");
const DrawArgs = @import("DrawArgs.zig");
const Comparer = @import("Comparer.zig");

pixels: []display_api.Display.Rgb,

pub fn initOwned(pixels_arg: []display_api.Display.Rgb) @This() {
    return .{ .pixels = pixels_arg };
}

pub fn comparer(self: *@This()) Comparer {
    return Comparer.from(@This(), self);
}

pub fn check(self: *@This(), draw: DrawArgs) display_error.Error!bool {
    _ = draw.x;
    _ = draw.y;
    _ = draw.w;
    _ = draw.h;
    if (self.pixels.len != draw.pixels.len) return false;
    return std.mem.eql(display_api.Display.Rgb, self.pixels, draw.pixels);
}
