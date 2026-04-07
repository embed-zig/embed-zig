const Self = @This();

r: u8,
g: u8,
b: u8,

pub fn init(r: u8, g: u8, b: u8) Self {
    return .{ .r = r, .g = g, .b = b };
}

pub fn cmp(self: Self, other: Self) bool {
    return self.r == other.r and self.g == other.g and self.b == other.b;
}

pub fn from565(pixel: u16) Self {
    const red5: u8 = @intCast((pixel >> 11) & 0x1F);
    const green6: u8 = @intCast((pixel >> 5) & 0x3F);
    const blue5: u8 = @intCast(pixel & 0x1F);
    return init(
        (red5 << 3) | (red5 >> 2),
        (green6 << 2) | (green6 >> 4),
        (blue5 << 3) | (blue5 >> 2),
    );
}

test "display/unit_tests/Rgb/cmp_compares_all_channels" {
    const testing = @import("std").testing;

    try testing.expect(init(1, 2, 3).cmp(init(1, 2, 3)));
    try testing.expect(!init(1, 2, 3).cmp(init(1, 2, 4)));
}

test "display/unit_tests/Rgb/from565_decodes_common_colors" {
    const testing = @import("std").testing;

    try testing.expect(init(0, 0, 0).cmp(from565(0x0000)));
    try testing.expect(init(255, 255, 255).cmp(from565(0xFFFF)));
    try testing.expect(init(255, 0, 0).cmp(from565(0xF800)));
    try testing.expect(init(0, 255, 0).cmp(from565(0x07E0)));
    try testing.expect(init(0, 0, 255).cmp(from565(0x001F)));
}

test "display/unit_tests/Rgb/from565_expands_partial_channels" {
    const testing = @import("std").testing;

    const decoded = from565(0x8410);
    try testing.expectEqual(@as(u8, 132), decoded.r);
    try testing.expectEqual(@as(u8, 130), decoded.g);
    try testing.expectEqual(@as(u8, 132), decoded.b);
}
