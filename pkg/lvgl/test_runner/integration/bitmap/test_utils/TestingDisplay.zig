const std = @import("std");
const embed = @import("embed");
const testing_api = @import("testing");
const display_api = @import("drivers");
const display_error = @import("Error.zig");
const DrawArgsType = @import("DrawArgs.zig");
const ComparerType = @import("Comparer.zig");
const BitmapComparerType = @import("BitmapComparer.zig");

const Allocator = std.mem.Allocator;
const Display = display_api.Display;
const Error = display_error.Error;
const Rgb = display_api.Display.Rgb;
const Self = @This();

pub const DrawArgs = DrawArgsType;
pub const Comparer = ComparerType;
pub const BitmapComparer = BitmapComparerType;

allocator: Allocator,
width_px: u16,
height_px: u16,
results: std.ArrayListUnmanaged(TestCaseResult) = .{},
next_result: usize = 0,
failure: ?Error = null,

pub const TestCaseResult = struct {
    case_index: usize,
    comparer: Comparer,
    owned_bitmap: ?*BitmapComparer = null,
};

const Adapter = struct {
    pub const Config = struct {
        allocator: Allocator,
        testing_display: *Self,
    };

    testing_display: *Self,

    pub fn init(config: Config) !@This() {
        return .{ .testing_display = config.testing_display };
    }

    pub fn deinit(_: *@This()) void {}

    pub fn width(self: *@This()) u16 {
        return self.testing_display.width_px;
    }

    pub fn height(self: *@This()) u16 {
        return self.testing_display.height_px;
    }

    pub fn drawBitmap(
        self: *@This(),
        x: u16,
        y: u16,
        w: u16,
        h: u16,
        pixels: []const Rgb,
    ) Error!void {
        return self.testing_display.recordDraw(x, y, w, h, pixels);
    }
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

pub fn display(self: *Self) !Display {
    return Display.make(std, Adapter).init(.{
        .allocator = self.allocator,
        .testing_display = self,
    });
}

/// Queue one expected draw. Use `comparer != null` for custom or piped logic (`pixels` ignored).
/// Use `comparer == null` to compare against `pixels` via an internal [`BitmapComparer`].
pub fn addTestCaseResult(
    self: *Self,
    case_index: usize,
    pixels: []const Rgb,
    comparer: ?Comparer,
) !void {
    if (comparer) |custom| {
        try self.results.append(self.allocator, .{
            .case_index = case_index,
            .comparer = custom,
        });
        return;
    }

    const owned_pixels = try self.allocator.dupe(Rgb, pixels);
    const bitmap = try self.allocator.create(BitmapComparer);
    bitmap.* = BitmapComparer.initOwned(owned_pixels);

    try self.results.append(self.allocator, .{
        .case_index = case_index,
        .comparer = bitmap.comparer(),
        .owned_bitmap = bitmap,
    });
}

pub fn assertComplete(self: *const Self) Error!void {
    if (self.failure) |err| return err;
    if (self.next_result != self.results.items.len) {
        return error.MissingDraw;
    }
}

pub fn pendingFailure(self: *const Self) ?Error {
    return self.failure;
}

fn recordDraw(
    self: *Self,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: []const Rgb,
) Error!void {
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

const CustomFirstComparer = struct {
    expected_first: Rgb,

    pub fn check(self: *const @This(), draw: DrawArgs) Error!bool {
        if (draw.pixels.len == 0) return error.Timeout;
        return self.expected_first.cmp(draw.pixels[0]);
    }
};

const FirstPixelRejectComparer = struct {
    expected_first: Rgb,

    pub fn check(self: *const @This(), draw: DrawArgs) Error!bool {
        if (draw.pixels.len == 0) return error.Timeout;
        if (!self.expected_first.cmp(draw.pixels[0])) return error.Timeout;
        return true;
    }
};

const LenIsFour = struct {
    pub fn check(self: *const @This(), draw: DrawArgs) Error!bool {
        _ = self;
        return draw.pixels.len == 4;
    }
};

const FirstPixelIsTestBitmapRed = struct {
    pub fn check(self: *const @This(), draw: DrawArgs) Error!bool {
        _ = self;
        if (draw.pixels.len == 0) return false;
        return draw.pixels[0].cmp(display_api.Display.rgb(255, 0, 0));
    }
};

fn testBitmap() [4]Rgb {
    return .{
        display_api.Display.rgb(255, 0, 0),
        display_api.Display.rgb(0, 255, 0),
        display_api.Display.rgb(0, 0, 255),
        display_api.Display.rgb(255, 255, 255),
    };
}

fn addDefaultTestCaseResult(
    testing_display: *Self,
    case_index: usize,
    comparer: ?Comparer,
) !void {
    const pixels = testBitmap();
    try testing_display.addTestCaseResult(case_index, &pixels, comparer);
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;

            const Cases = struct {
                fn comparesExpectedDrawsInOrder(alloc: std.mem.Allocator) !void {
                    var testing_display = Self.init(alloc, 8, 4);
                    defer testing_display.deinit();

                    const pixels = testBitmap();

                    try addDefaultTestCaseResult(&testing_display, 0, null);

                    var output = try testing_display.display();
                    defer output.deinit();
                    try lib.testing.expectEqual(@as(u16, 8), output.width());
                    try lib.testing.expectEqual(@as(u16, 4), output.height());
                    try output.drawBitmap(1, 1, 2, 2, &pixels);
                    try testing_display.assertComplete();
                }

                fn reportsDrawMismatches(alloc: std.mem.Allocator) !void {
                    var testing_display = Self.init(alloc, 8, 4);
                    defer testing_display.deinit();

                    const actual = [_]Rgb{
                        display_api.Display.rgb(0, 0, 0),
                        display_api.Display.rgb(0, 0, 0),
                        display_api.Display.rgb(0, 0, 0),
                        display_api.Display.rgb(0, 0, 0),
                    };

                    try addDefaultTestCaseResult(&testing_display, 0, null);

                    var output = try testing_display.display();
                    defer output.deinit();
                    try lib.testing.expectError(error.DisplayError, output.drawBitmap(1, 1, 2, 2, &actual));
                    try lib.testing.expectEqual(@as(?Error, error.DrawPixelsMismatch), testing_display.pendingFailure());
                    try lib.testing.expectError(error.DrawPixelsMismatch, testing_display.assertComplete());
                }

                fn pipeComparerRunsComparersInOrderOnOneDraw(alloc: std.mem.Allocator) !void {
                    const PipeComparer = @import("PipeComparer.zig");
                    var testing_display = Self.init(alloc, 8, 4);
                    defer testing_display.deinit();

                    var len_ok = LenIsFour{};
                    var red_ok = FirstPixelIsTestBitmapRed{};
                    var steps = [_]Comparer{
                        Comparer.from(LenIsFour, &len_ok),
                        Comparer.from(FirstPixelIsTestBitmapRed, &red_ok),
                    };
                    var pipe = PipeComparer.init(steps[0..]);
                    try testing_display.addTestCaseResult(0, &[_]Rgb{}, pipe.comparer());

                    const pixels = testBitmap();
                    var output = try testing_display.display();
                    defer output.deinit();
                    try output.drawBitmap(1, 1, 2, 2, &pixels);
                    try testing_display.assertComplete();
                }

                fn supportsCustomBitmapComparer(alloc: std.mem.Allocator) !void {
                    var testing_display = Self.init(alloc, 8, 4);
                    defer testing_display.deinit();

                    const pixels = testBitmap();
                    var comparer = CustomFirstComparer{
                        .expected_first = pixels[0],
                    };

                    try testing_display.addTestCaseResult(0, &[_]Rgb{}, Comparer.from(CustomFirstComparer, &comparer));

                    var output = try testing_display.display();
                    defer output.deinit();
                    try output.drawBitmap(1, 1, 2, 2, &pixels);
                    try testing_display.assertComplete();
                }

                fn consumesQueuedBitmapAnswersInOrder(alloc: std.mem.Allocator) !void {
                    var testing_display = Self.init(alloc, 8, 4);
                    defer testing_display.deinit();

                    const first = [_]Rgb{
                        display_api.Display.rgb(255, 0, 0),
                        display_api.Display.rgb(0, 255, 0),
                        display_api.Display.rgb(0, 0, 255),
                        display_api.Display.rgb(255, 255, 255),
                    };
                    const second = [_]Rgb{
                        display_api.Display.rgb(1, 2, 3),
                        display_api.Display.rgb(4, 5, 6),
                        display_api.Display.rgb(7, 8, 9),
                        display_api.Display.rgb(10, 11, 12),
                    };

                    try testing_display.addTestCaseResult(0, &first, null);
                    try testing_display.addTestCaseResult(1, &second, null);

                    var output = try testing_display.display();
                    defer output.deinit();
                    try output.drawBitmap(0, 0, 2, 2, &first);
                    try output.drawBitmap(5, 1, 2, 2, &second);
                    try testing_display.assertComplete();
                }

                fn customComparerCanRejectBitmapOutput(alloc: std.mem.Allocator) !void {
                    var testing_display = Self.init(alloc, 8, 4);
                    defer testing_display.deinit();

                    const expected = testBitmap();
                    const actual = [_]Rgb{
                        display_api.Display.rgb(0, 0, 0),
                        display_api.Display.rgb(0, 255, 0),
                        display_api.Display.rgb(0, 0, 255),
                        display_api.Display.rgb(255, 255, 255),
                    };
                    var comparer = FirstPixelRejectComparer{
                        .expected_first = expected[0],
                    };

                    try testing_display.addTestCaseResult(0, &[_]Rgb{}, Comparer.from(FirstPixelRejectComparer, &comparer));

                    var output = try testing_display.display();
                    defer output.deinit();
                    try lib.testing.expectError(error.Timeout, output.drawBitmap(1, 1, 2, 2, &actual));
                    try lib.testing.expectError(error.Timeout, testing_display.assertComplete());
                }
            };

            const alloc = allocator;
            Cases.comparesExpectedDrawsInOrder(alloc) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.reportsDrawMismatches(alloc) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.pipeComparerRunsComparersInOrderOnOneDraw(alloc) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.supportsCustomBitmapComparer(alloc) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.consumesQueuedBitmapAnswersInOrder(alloc) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.customComparerCanRejectBitmapOutput(alloc) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
