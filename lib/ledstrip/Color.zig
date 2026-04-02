//! ledstrip.Color — RGB color helpers for LED strips.

const root = @This();

r: u8 = 0,
g: u8 = 0,
b: u8 = 0,

pub const black = root{};
pub const white = root{ .r = 255, .g = 255, .b = 255 };
pub const red = root{ .r = 255 };
pub const green = root{ .g = 255 };
pub const blue = root{ .b = 255 };

pub fn rgb(r: u8, g: u8, b: u8) root {
    return .{ .r = r, .g = g, .b = b };
}

pub fn withBrightness(self: root, brightness: u8) root {
    return .{
        .r = @intCast((@as(u16, self.r) * brightness) / 255),
        .g = @intCast((@as(u16, self.g) * brightness) / 255),
        .b = @intCast((@as(u16, self.b) * brightness) / 255),
    };
}

pub fn lerp(a: root, b: root, t: u8) root {
    const inv_t: u16 = 255 - t;
    return .{
        .r = @intCast((@as(u16, a.r) * inv_t + @as(u16, b.r) * t) / 255),
        .g = @intCast((@as(u16, a.g) * inv_t + @as(u16, b.g) * t) / 255),
        .b = @intCast((@as(u16, a.b) * inv_t + @as(u16, b.b) * t) / 255),
    };
}

test "ledstrip/unit_tests/Color_rgb_and_named_constants_match" {
    const std = @import("std");

    try std.testing.expectEqual(red, rgb(255, 0, 0));
    try std.testing.expectEqual(green, rgb(0, 255, 0));
    try std.testing.expectEqual(blue, rgb(0, 0, 255));
    try std.testing.expectEqual(white, rgb(255, 255, 255));
    try std.testing.expectEqual(black, rgb(0, 0, 0));
}

test "ledstrip/unit_tests/Color_withBrightness_scales_channels" {
    const std = @import("std");

    const color = rgb(255, 128, 64).withBrightness(128);
    try std.testing.expectEqual(root.rgb(128, 64, 32), color);
}

test "ledstrip/unit_tests/Color_lerp_interpolates_endpoints_and_midpoint" {
    const std = @import("std");

    try std.testing.expectEqual(red, lerp(red, blue, 0));
    try std.testing.expectEqual(blue, lerp(red, blue, 255));

    const mid = lerp(red, blue, 128);
    try std.testing.expectEqual(@as(u8, 127), mid.r);
    try std.testing.expectEqual(@as(u8, 0), mid.g);
    try std.testing.expectEqual(@as(u8, 128), mid.b);
}
