const std = @import("std");
const hal = struct {
    pub const led_strip = @import("../../../hal/led_strip.zig");
};

pub const Color = hal.led_strip.Color;

pub fn Frame(comptime n: u32) type {
    return struct {
        const Self = @This();
        pub const pixel_count = n;

        pixels: [n]Color = [_]Color{Color.black} ** n,

        pub fn solid(color: Color) Self {
            var f: Self = .{};
            @memset(&f.pixels, color);
            return f;
        }

        pub fn gradient(from: Color, to: Color) Self {
            var f: Self = .{};
            if (n <= 1) {
                f.pixels[0] = from;
                return f;
            }
            for (0..n) |i| {
                const t: u8 = @intCast((i * 255) / (n - 1));
                f.pixels[i] = Color.lerp(from, to, t);
            }
            return f;
        }

        pub fn rotate(self: Self) Self {
            var f: Self = .{};
            for (0..n - 1) |i| {
                f.pixels[i] = self.pixels[i + 1];
            }
            f.pixels[n - 1] = self.pixels[0];
            return f;
        }

        pub fn flip(self: Self) Self {
            var f: Self = .{};
            for (0..n) |i| {
                f.pixels[i] = self.pixels[n - 1 - i];
            }
            return f;
        }

        pub fn withBrightness(self: Self, brightness: u8) Self {
            var f: Self = .{};
            for (0..n) |i| {
                f.pixels[i] = self.pixels[i].withBrightness(brightness);
            }
            return f;
        }

        pub fn eql(a: Self, b: Self) bool {
            return std.mem.eql(Color, &a.pixels, &b.pixels);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Frame: solid" {
    const F = Frame(4);
    const f = F.solid(Color.red);
    for (f.pixels) |p| {
        try testing.expectEqual(Color.red, p);
    }
}

test "Frame: gradient endpoints" {
    const F = Frame(8);
    const f = F.gradient(Color.red, Color.blue);
    try testing.expectEqual(Color.red, f.pixels[0]);
    try testing.expectEqual(Color.blue, f.pixels[7]);
}

test "Frame: rotate shifts left" {
    const F = Frame(4);
    var f: F = .{};
    f.pixels[0] = Color.red;
    f.pixels[1] = Color.green;
    f.pixels[2] = Color.blue;
    f.pixels[3] = Color.white;
    const r = f.rotate();
    try testing.expectEqual(Color.green, r.pixels[0]);
    try testing.expectEqual(Color.blue, r.pixels[1]);
    try testing.expectEqual(Color.white, r.pixels[2]);
    try testing.expectEqual(Color.red, r.pixels[3]);
}

test "Frame: flip reverses" {
    const F = Frame(3);
    var f: F = .{};
    f.pixels[0] = Color.red;
    f.pixels[1] = Color.green;
    f.pixels[2] = Color.blue;
    const fl = f.flip();
    try testing.expectEqual(Color.blue, fl.pixels[0]);
    try testing.expectEqual(Color.green, fl.pixels[1]);
    try testing.expectEqual(Color.red, fl.pixels[2]);
}

test "Frame: withBrightness scales" {
    const F = Frame(1);
    const f = F.solid(Color.white).withBrightness(128);
    try testing.expect(f.pixels[0].r < 200);
    try testing.expect(f.pixels[0].r > 100);
}

test "Frame: eql" {
    const F = Frame(2);
    const a = F.solid(Color.red);
    const b = F.solid(Color.red);
    const c = F.solid(Color.green);
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
}
