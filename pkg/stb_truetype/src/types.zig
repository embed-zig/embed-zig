pub const VMetrics = struct {
    ascent: i32,
    descent: i32,
    line_gap: i32,
};

pub const HMetrics = struct {
    advance_width: i32,
    left_side_bearing: i32,
};

pub const BitmapBox = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub fn width(self: @This()) i32 {
        return self.x1 - self.x0;
    }

    pub fn height(self: @This()) i32 {
        return self.y1 - self.y0;
    }
};

test "stb_truetype/unit_tests/types/bitmap_box_dimensions" {
    const std = @import("std");
    const testing = std.testing;

    const box = BitmapBox{
        .x0 = -3,
        .y0 = -7,
        .x1 = 9,
        .y1 = 5,
    };

    try testing.expectEqual(@as(i32, 12), box.width());
    try testing.expectEqual(@as(i32, 12), box.height());
}
