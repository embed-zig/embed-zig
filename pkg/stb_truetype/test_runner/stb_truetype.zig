const embed = @import("embed");
const testing_api = @import("testing");
const FontMod = @import("../src/Font.zig");
const types_mod = @import("../src/types.zig");
const font_bytes = @embedFile("font.ttf");
const embedded_codepoint: u21 = 0x4E2D;

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            runImpl(lib) catch |err| {
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

fn runImpl(comptime lib: type) !void {
    const stb = struct {
        pub const Font = FontMod;
        pub const VMetrics = types_mod.VMetrics;
        pub const HMetrics = types_mod.HMetrics;
        pub const BitmapBox = types_mod.BitmapBox;
    };
    const testing = lib.testing;

    const empty = [_]u8{};
    const invalid = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    const ascii_noise = [_]u8{ 'n', 'o', 't', '-', 'a', '-', 'f', 'o', 'n', 't' };

    try testing.expectError(stb.Font.InitError.InvalidFont, stb.Font.init(empty[0..]));
    try testing.expectError(stb.Font.InitError.InvalidFont, stb.Font.init(invalid[0..]));
    try testing.expectError(stb.Font.InitError.InvalidFont, stb.Font.init(ascii_noise[0..]));
    try testing.expectError(stb.Font.InitError.InvalidFont, stb.Font.initOffset(invalid[0..], 2));
    try testing.expectError(stb.Font.InitError.InvalidFont, stb.Font.initOffset(ascii_noise[0..], ascii_noise.len));

    const embedded_font = try stb.Font.init(font_bytes[0..]);
    try testing.expect(embedded_font.glyphIndex(embedded_codepoint) > 0);

    const scale = embedded_font.scaleForPixelHeight(24.0);
    try testing.expect(scale > 0);
    try testing.expect(embedded_font.scaleForMappingEmToPixels(24.0) > 0);

    const font_metrics = embedded_font.vMetrics();
    try testing.expect(font_metrics.ascent > 0);
    try testing.expect(font_metrics.descent <= 0);

    const glyph_metrics = embedded_font.hMetrics(embedded_codepoint);
    try testing.expect(glyph_metrics.advance_width > 0);

    const glyph_box = embedded_font.bitmapBox(embedded_codepoint, scale, scale);
    try testing.expect(glyph_box.width() > 0);
    try testing.expect(glyph_box.height() > 0);

    const bitmap_len: usize = @intCast(glyph_box.width() * glyph_box.height());
    const bitmap = try testing.allocator.alloc(u8, bitmap_len);
    defer testing.allocator.free(bitmap);
    @memset(bitmap, 0);
    embedded_font.renderCodepointBitmap(
        bitmap,
        @intCast(glyph_box.width()),
        @intCast(glyph_box.height()),
        @intCast(glyph_box.width()),
        scale,
        scale,
        embedded_codepoint,
    );
    try testing.expect(hasNonZeroByte(bitmap));

    const box = stb.BitmapBox{
        .x0 = -3,
        .y0 = -7,
        .x1 = 9,
        .y1 = 5,
    };
    try testing.expectEqual(@as(i32, 12), box.width());
    try testing.expectEqual(@as(i32, 12), box.height());

    const metrics = stb.VMetrics{
        .ascent = 10,
        .descent = -2,
        .line_gap = 3,
    };
    const h_metrics = stb.HMetrics{
        .advance_width = 14,
        .left_side_bearing = -1,
    };

    try testing.expectEqual(@as(i32, 10), metrics.ascent);
    try testing.expectEqual(@as(i32, -2), metrics.descent);
    try testing.expectEqual(@as(i32, 3), metrics.line_gap);
    try testing.expectEqual(@as(i32, 14), h_metrics.advance_width);
    try testing.expectEqual(@as(i32, -1), h_metrics.left_side_bearing);
}

fn hasNonZeroByte(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b != 0) return true;
    }
    return false;
}
