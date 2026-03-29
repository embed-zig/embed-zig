const std = @import("std");
const display_mod = @import("../Display.zig");
const DrawArgsType = @import("DrawArgs.zig");
const ComparerType = @import("Comparer.zig");
const BitmapComparerType = @import("BitmapComparer.zig");

const Allocator = std.mem.Allocator;
const Color565 = display_mod.Color565;
const Self = @This();

pub const TestingDisplay = Self;

pub const DrawArgs = DrawArgsType;
pub const Comparer = ComparerType;
pub const BitmapComparer = BitmapComparerType;

allocator: Allocator,
width_px: u16,
height_px: u16,
results: std.ArrayListUnmanaged(TestCaseResult) = .{},
next_result: usize = 0,
failure: ?display_mod.Error = null,

pub const TestCaseResult = struct {
    case_index: usize,
    comparer: Comparer,
    owned_bitmap: ?*BitmapComparer = null,
};

pub fn init(allocator: Allocator, width_px: u16, height_px: u16) Self {
    return .{
        .allocator = allocator,
        .width_px = width_px,
        .height_px = height_px,
    };
}

pub fn deinit(self: *Self) void {
    for (self.results.items) |item| {
        if (item.owned_bitmap) |bitmap| {
            self.allocator.free(bitmap.pixels);
            self.allocator.destroy(bitmap);
        }
    }
    self.results.deinit(self.allocator);
}

pub fn display(self: *Self) display_mod.Display {
    return display_mod.Display.init(self, &vtable);
}

/// Queue one expected draw. Use `comparer != null` for custom or piped logic (`pixels` ignored).
/// Use `comparer == null` to compare against `pixels` via an internal [`BitmapComparer`].
pub fn addTestCaseResult(
    self: *Self,
    case_index: usize,
    pixels: []const Color565,
    comparer: ?Comparer,
) !void {
    if (comparer) |custom| {
        try self.results.append(self.allocator, .{
            .case_index = case_index,
            .comparer = custom,
        });
        return;
    }

    const owned_pixels = try self.allocator.dupe(Color565, pixels);
    const bitmap = try self.allocator.create(BitmapComparer);
    bitmap.* = BitmapComparer.initOwned(owned_pixels);

    try self.results.append(self.allocator, .{
        .case_index = case_index,
        .comparer = bitmap.comparer(),
        .owned_bitmap = bitmap,
    });
}

pub fn assertComplete(self: *const Self) display_mod.Error!void {
    if (self.failure) |err| return err;
    if (self.next_result != self.results.items.len) {
        return error.MissingDraw;
    }
}

fn width(ctx: *const anyopaque) u16 {
    const self: *const Self = @ptrCast(@alignCast(ctx));
    return self.width_px;
}

fn height(ctx: *const anyopaque) u16 {
    const self: *const Self = @ptrCast(@alignCast(ctx));
    return self.height_px;
}

fn drawBitmap(
    ctx: *anyopaque,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: []const Color565,
) display_mod.Error!void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (self.failure) |err| return err;

    if (self.next_result >= self.results.items.len) {
        self.failure = error.UnexpectedDraw;
        return error.UnexpectedDraw;
    }

    const expected = self.results.items[self.next_result];
    self.next_result += 1;

    const draw = DrawArgs{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .pixels = pixels,
    };

    const ok = expected.comparer.check(draw) catch |err| {
        self.failure = err;
        return err;
    };
    if (!ok) {
        self.failure = error.DrawPixelsMismatch;
        return error.DrawPixelsMismatch;
    }

    if (self.failure) |err| {
        return err;
    }
}

const vtable = display_mod.VTable{
    .width_fn = width,
    .height_fn = height,
    .draw_bitmap_fn = drawBitmap,
};

const CustomFirstComparer = struct {
    expected_first: Color565,

    pub fn check(self: *const @This(), draw: DrawArgs) display_mod.Error!bool {
        if (draw.pixels.len == 0) return error.Timeout;
        return self.expected_first == draw.pixels[0];
    }
};

const FirstPixelRejectComparer = struct {
    expected_first: Color565,

    pub fn check(self: *const @This(), draw: DrawArgs) display_mod.Error!bool {
        if (draw.pixels.len == 0) return error.Timeout;
        if (self.expected_first != draw.pixels[0]) return error.Timeout;
        return true;
    }
};

const LenIsFour = struct {
    pub fn check(self: *const @This(), draw: DrawArgs) display_mod.Error!bool {
        _ = self;
        return draw.pixels.len == 4;
    }
};

const FirstPixelIsTestBitmapRed = struct {
    pub fn check(self: *const @This(), draw: DrawArgs) display_mod.Error!bool {
        _ = self;
        if (draw.pixels.len == 0) return false;
        return draw.pixels[0] == display_mod.rgb565(255, 0, 0);
    }
};

fn testBitmap() [4]Color565 {
    return .{
        display_mod.rgb565(255, 0, 0),
        display_mod.rgb565(0, 255, 0),
        display_mod.rgb565(0, 0, 255),
        display_mod.rgb565(255, 255, 255),
    };
}

fn addDefaultTestCaseResult(
    testing_display: *TestingDisplay,
    case_index: usize,
    comparer: ?Comparer,
) !void {
    const pixels = testBitmap();
    try testing_display.addTestCaseResult(case_index, &pixels, comparer);
}

test "lvgl/unit_tests/test_runner/display/TestingDisplay/compares_expected_draws_in_order" {
    const testing = std.testing;

    var testing_display = TestingDisplay.init(testing.allocator, 8, 4);
    defer testing_display.deinit();

    const pixels = testBitmap();

    try addDefaultTestCaseResult(&testing_display, 0, null);

    const output = testing_display.display();
    try testing.expectEqual(@as(u16, 8), output.width());
    try testing.expectEqual(@as(u16, 4), output.height());
    try output.drawBitmap(1, 1, 2, 2, &pixels);
    try testing_display.assertComplete();
}

test "lvgl/unit_tests/test_runner/display/TestingDisplay/reports_draw_mismatches" {
    const testing = std.testing;

    var testing_display = TestingDisplay.init(testing.allocator, 8, 4);
    defer testing_display.deinit();

    const actual = [_]Color565{
        display_mod.rgb565(0, 0, 0),
        display_mod.rgb565(0, 0, 0),
        display_mod.rgb565(0, 0, 0),
        display_mod.rgb565(0, 0, 0),
    };

    try addDefaultTestCaseResult(&testing_display, 0, null);

    const output = testing_display.display();
    try testing.expectError(error.DrawPixelsMismatch, output.drawBitmap(1, 1, 2, 2, &actual));
    try testing.expectError(error.DrawPixelsMismatch, testing_display.assertComplete());
}

test "lvgl/unit_tests/test_runner/display/TestingDisplay/pipe_comparer_runs_comparers_in_order_on_one_draw" {
    const PipeComparer = @import("PipeComparer.zig");
    const testing = std.testing;

    var testing_display = TestingDisplay.init(testing.allocator, 8, 4);
    defer testing_display.deinit();

    var len_ok = LenIsFour{};
    var red_ok = FirstPixelIsTestBitmapRed{};
    var steps = [_]Comparer{
        Comparer.from(LenIsFour, &len_ok),
        Comparer.from(FirstPixelIsTestBitmapRed, &red_ok),
    };
    var pipe = PipeComparer.init(steps[0..]);
    try testing_display.addTestCaseResult(0, &[_]Color565{}, pipe.comparer());

    const pixels = testBitmap();
    const output = testing_display.display();
    try output.drawBitmap(1, 1, 2, 2, &pixels);
    try testing_display.assertComplete();
}

test "lvgl/unit_tests/test_runner/display/TestingDisplay/supports_custom_bitmap_comparer" {
    const testing = std.testing;

    var testing_display = TestingDisplay.init(testing.allocator, 8, 4);
    defer testing_display.deinit();

    const pixels = testBitmap();
    var comparer = CustomFirstComparer{
        .expected_first = pixels[0],
    };

    try testing_display.addTestCaseResult(0, &[_]Color565{}, Comparer.from(CustomFirstComparer, &comparer));

    const output = testing_display.display();
    try output.drawBitmap(1, 1, 2, 2, &pixels);
    try testing_display.assertComplete();
}

test "lvgl/unit_tests/test_runner/display/TestingDisplay/consumes_queued_bitmap_answers_in_order" {
    const testing = std.testing;

    var testing_display = TestingDisplay.init(testing.allocator, 8, 4);
    defer testing_display.deinit();

    const first = [_]Color565{
        display_mod.rgb565(255, 0, 0),
        display_mod.rgb565(0, 255, 0),
        display_mod.rgb565(0, 0, 255),
        display_mod.rgb565(255, 255, 255),
    };
    const second = [_]Color565{
        display_mod.rgb565(1, 2, 3),
        display_mod.rgb565(4, 5, 6),
        display_mod.rgb565(7, 8, 9),
        display_mod.rgb565(10, 11, 12),
    };

    try testing_display.addTestCaseResult(0, &first, null);
    try testing_display.addTestCaseResult(1, &second, null);

    const output = testing_display.display();
    try output.drawBitmap(0, 0, 2, 2, &first);
    try output.drawBitmap(5, 1, 2, 2, &second);
    try testing_display.assertComplete();
}

test "lvgl/unit_tests/test_runner/display/TestingDisplay/custom_comparer_can_reject_bitmap_output" {
    const testing = std.testing;

    var testing_display = TestingDisplay.init(testing.allocator, 8, 4);
    defer testing_display.deinit();

    const expected = testBitmap();
    const actual = [_]Color565{
        display_mod.rgb565(0, 0, 0),
        display_mod.rgb565(0, 255, 0),
        display_mod.rgb565(0, 0, 255),
        display_mod.rgb565(255, 255, 255),
    };
    var comparer = FirstPixelRejectComparer{
        .expected_first = expected[0],
    };

    try testing_display.addTestCaseResult(0, &[_]Color565{}, Comparer.from(FirstPixelRejectComparer, &comparer));

    const output = testing_display.display();
    try testing.expectError(error.Timeout, output.drawBitmap(1, 1, 2, 2, &actual));
    try testing.expectError(error.Timeout, testing_display.assertComplete());
}
