const std = @import("std");
const testing = std.testing;
const module = @import("led_strip.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const embed = struct {
    pub const hal = struct {
        pub const led_strip = @import("../../hal/led_strip.zig");
    };
};
const Color = embed.hal.led_strip.Color;
const max_pixels = module.max_pixels;
const LedStrip = module.LedStrip;

test "websim led_strip satisfies hal contract" {
    const LedStripHal = embed.hal.led_strip.from(struct {
        pub const Driver = LedStrip;
        pub const meta = .{ .id = "led_strip.websim" };
    });

    var drv = LedStrip.init();
    var strip = LedStripHal.init(&drv);

    try std.testing.expectEqual(@as(u32, 1), strip.getPixelCount());

    strip.setPixel(0, Color.red);
    try std.testing.expectEqual(Color.red, drv.pixels[0]);
}
