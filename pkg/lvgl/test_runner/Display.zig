pub const Error = error{
    OutOfBounds,
    Busy,
    Timeout,
    DisplayError,
    UnexpectedDraw,
    MissingDraw,
    DrawAreaMismatch,
    DrawPixelsMismatch,
};

pub const Color565 = u16;

pub fn rgb565(r: u8, g: u8, b: u8) Color565 {
    const rr: u16 = (@as(u16, r) >> 3) & 0x1F;
    const gg: u16 = (@as(u16, g) >> 2) & 0x3F;
    const bb: u16 = (@as(u16, b) >> 3) & 0x1F;
    return (rr << 11) | (gg << 5) | bb;
}

pub const VTable = struct {
    width_fn: *const fn (ctx: *const anyopaque) u16,
    height_fn: *const fn (ctx: *const anyopaque) u16,
    draw_bitmap_fn: *const fn (
        ctx: *anyopaque,
        x: u16,
        y: u16,
        w: u16,
        h: u16,
        data: []const Color565,
    ) Error!void,
};

const Self = @This();

pub const Display = Self;

ctx: *anyopaque,
vtable: *const VTable,

pub fn init(ctx: *anyopaque, vtable: *const VTable) Self {
    return .{
        .ctx = ctx,
        .vtable = vtable,
    };
}

pub fn width(self: *const Self) u16 {
    return self.vtable.width_fn(@ptrCast(self.ctx));
}

pub fn height(self: *const Self) u16 {
    return self.vtable.height_fn(@ptrCast(self.ctx));
}

pub fn drawBitmap(
    self: *const Self,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    data: []const Color565,
) Error!void {
    if (w == 0 or h == 0) return;
    if (@as(u32, x) + w > self.width() or @as(u32, y) + h > self.height()) {
        return error.OutOfBounds;
    }
    if (data.len < @as(usize, w) * @as(usize, h)) {
        return error.OutOfBounds;
    }
    return self.vtable.draw_bitmap_fn(self.ctx, x, y, w, h, data);
}

test "lvgl/unit_tests/test_runner/Display/wrapper_delegates_geometry_and_draw_calls" {
    const testing = @import("std").testing;

    const Mock = struct {
        width_px: u16 = 8,
        height_px: u16 = 4,
        draws: usize = 0,
        last_x: u16 = 0,
        last_y: u16 = 0,
        last_w: u16 = 0,
        last_h: u16 = 0,
        last_pixels: []const Color565 = &.{},

        const vtable = VTable{
            .width_fn = @This().width,
            .height_fn = @This().height,
            .draw_bitmap_fn = @This().drawBitmap,
        };

        fn width(ctx: *const anyopaque) u16 {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            return self.width_px;
        }

        fn height(ctx: *const anyopaque) u16 {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            return self.height_px;
        }

        fn drawBitmap(ctx: *anyopaque, x: u16, y: u16, w: u16, h: u16, data: []const Color565) Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.draws += 1;
            self.last_x = x;
            self.last_y = y;
            self.last_w = w;
            self.last_h = h;
            self.last_pixels = data;
        }

        fn display(self: *@This()) Display {
            return Display.init(self, &vtable);
        }
    };

    var mock = Mock{};
    const display = mock.display();
    const pixels = [_]Color565{
        rgb565(255, 0, 0),
        rgb565(0, 255, 0),
        rgb565(0, 0, 255),
        rgb565(255, 255, 255),
    };

    try testing.expectEqual(@as(u16, 8), display.width());
    try testing.expectEqual(@as(u16, 4), display.height());
    try display.drawBitmap(1, 1, 2, 2, &pixels);
    try testing.expectEqual(@as(usize, 1), mock.draws);
    try testing.expectEqual(@as(u16, 1), mock.last_x);
    try testing.expectEqual(@as(u16, 1), mock.last_y);
    try testing.expectEqual(@as(u16, 2), mock.last_w);
    try testing.expectEqual(@as(u16, 2), mock.last_h);
    try testing.expectEqualSlices(Color565, &pixels, mock.last_pixels);
}

test "lvgl/unit_tests/test_runner/Display/wrapper_validates_bounds_before_calling_backend" {
    const testing = @import("std").testing;

    const Mock = struct {
        const vtable = VTable{
            .width_fn = @This().width,
            .height_fn = @This().height,
            .draw_bitmap_fn = @This().drawBitmap,
        };

        fn width(_: *const anyopaque) u16 {
            return 4;
        }

        fn height(_: *const anyopaque) u16 {
            return 4;
        }

        fn drawBitmap(_: *anyopaque, _: u16, _: u16, _: u16, _: u16, _: []const Color565) Error!void {}
    };

    var ctx: u8 = 0;
    const display = Display.init(&ctx, &Mock.vtable);
    const pixels = [_]Color565{rgb565(255, 0, 0)} ** 4;

    try testing.expectError(error.OutOfBounds, display.drawBitmap(3, 3, 2, 2, &pixels));
    try testing.expectError(error.OutOfBounds, display.drawBitmap(0, 0, 2, 2, pixels[0..3]));
}
