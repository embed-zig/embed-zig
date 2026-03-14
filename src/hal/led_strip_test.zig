const module = @import("led_strip.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Color = module.Color;
const is = module.is;
const from = module.from;
const hal_marker = test_exports.hal_marker;

const std = @import("std");
const testing = std.testing;

test "led strip wrapper" {
    const Mock = struct {
        pixels: [8]Color = [_]Color{.black} ** 8,
        refresh_count: u32 = 0,

        pub fn setPixel(self: *@This(), index: u32, color: Color) void {
            self.pixels[index] = color;
        }
        pub fn getPixelCount(_: *@This()) u32 {
            return 8;
        }
        pub fn refresh(self: *@This()) void {
            self.refresh_count += 1;
        }
    };

    const Strip = from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "ledstrip.test" };
    });

    var d = Mock{};
    var strip = Strip.init(&d);
    strip.setColor(.red);
    try std.testing.expectEqual(Color.red, d.pixels[0]);
    strip.setBrightness(128);
    strip.setColor(.white);
    try std.testing.expect(d.pixels[0].r < 200);
    strip.setEnabled(false);
    try std.testing.expectEqual(Color.black, d.pixels[0]);
    try std.testing.expect(d.refresh_count > 0);
}
