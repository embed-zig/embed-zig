const binding = @import("binding.zig");
const types = @import("types.zig");

const Self = @This();

info: binding.FontInfo,
data: []const u8,

pub const VMetrics = types.VMetrics;
pub const HMetrics = types.HMetrics;
pub const BitmapBox = types.BitmapBox;

pub const InitError = error{
    InvalidFont,
    OffsetTooLarge,
};

pub const RenderCodepointBitmapError = error{
    BitmapTooLarge,
    BufferTooSmall,
    DimensionTooLarge,
    InvalidStride,
};

/// Initializes a font that borrows the provided font bytes.
///
/// The caller must keep `data` alive and unchanged for as long as the returned
/// `Font` is used, because `stbtt_fontinfo` keeps pointers into the original
/// font buffer.
pub fn init(data: []const u8) InitError!Self {
    return initOffset(data, 0);
}

/// Initializes a font from the font data starting at `offset`.
///
/// The caller must keep `data` alive and unchanged for as long as the returned
/// `Font` is used, because `stbtt_fontinfo` keeps pointers into the original
/// font buffer.
pub fn initOffset(data: []const u8, offset: usize) InitError!Self {
    const min_font_header_len = 12;
    if (offset > data.len or data.len - offset < min_font_header_len) {
        return error.InvalidFont;
    }

    const c_offset = try intCastFontOffset(offset);

    var self: Self = .{
        .info = undefined,
        .data = data,
    };
    if (binding.stbtt_InitFont(&self.info, data.ptr, c_offset) == 0) {
        return error.InvalidFont;
    }
    return self;
}

pub fn scaleForPixelHeight(self: *const Self, pixels: f32) f32 {
    return binding.stbtt_ScaleForPixelHeight(&self.info, pixels);
}

pub fn scaleForMappingEmToPixels(self: *const Self, pixels: f32) f32 {
    return binding.stbtt_ScaleForMappingEmToPixels(&self.info, pixels);
}

pub fn vMetrics(self: *const Self) VMetrics {
    var ascent: c_int = 0;
    var descent: c_int = 0;
    var line_gap: c_int = 0;
    binding.stbtt_GetFontVMetrics(&self.info, &ascent, &descent, &line_gap);
    return .{
        .ascent = ascent,
        .descent = descent,
        .line_gap = line_gap,
    };
}

pub fn hMetrics(self: *const Self, codepoint: u21) HMetrics {
    var advance_width: c_int = 0;
    var left_side_bearing: c_int = 0;
    binding.stbtt_GetCodepointHMetrics(
        &self.info,
        @intCast(codepoint),
        &advance_width,
        &left_side_bearing,
    );
    return .{
        .advance_width = advance_width,
        .left_side_bearing = left_side_bearing,
    };
}

pub fn kernAdvance(self: *const Self, left: u21, right: u21) i32 {
    return binding.stbtt_GetCodepointKernAdvance(&self.info, @intCast(left), @intCast(right));
}

pub fn bitmapBox(self: *const Self, codepoint: u21, scale_x: f32, scale_y: f32) BitmapBox {
    var x0: c_int = 0;
    var y0: c_int = 0;
    var x1: c_int = 0;
    var y1: c_int = 0;
    binding.stbtt_GetCodepointBitmapBox(
        &self.info,
        @intCast(codepoint),
        scale_x,
        scale_y,
        &x0,
        &y0,
        &x1,
        &y1,
    );
    return .{
        .x0 = x0,
        .y0 = y0,
        .x1 = x1,
        .y1 = y1,
    };
}

pub fn renderCodepointBitmap(
    self: *const Self,
    output: []u8,
    width: usize,
    height: usize,
    stride: usize,
    scale_x: f32,
    scale_y: f32,
    codepoint: u21,
) RenderCodepointBitmapError!void {
    const required_len = try requiredBitmapLen(width, height, stride);
    if (output.len < required_len) {
        return error.BufferTooSmall;
    }
    if (required_len == 0) return;

    binding.stbtt_MakeCodepointBitmap(
        &self.info,
        output.ptr,
        try intCastBitmapDimension(width),
        try intCastBitmapDimension(height),
        try intCastBitmapDimension(stride),
        scale_x,
        scale_y,
        @intCast(codepoint),
    );
}

/// Returns `0` when the font does not provide a glyph for `codepoint`.
pub fn glyphIndex(self: *const Self, codepoint: u21) i32 {
    return binding.stbtt_FindGlyphIndex(&self.info, @intCast(codepoint));
}

fn intCastFontOffset(value: usize) InitError!c_int {
    if (value > maxCIntValue()) return error.OffsetTooLarge;
    return @intCast(value);
}

fn requiredBitmapLen(width: usize, height: usize, stride: usize) RenderCodepointBitmapError!usize {
    if (width == 0 or height == 0) return 0;
    if (stride < width) return error.InvalidStride;

    const last_row_offset, const offset_overflow = @mulWithOverflow(height - 1, stride);
    if (offset_overflow != 0) return error.BitmapTooLarge;

    const required_len, const len_overflow = @addWithOverflow(last_row_offset, width);
    if (len_overflow != 0) return error.BitmapTooLarge;

    return required_len;
}

fn intCastBitmapDimension(value: usize) RenderCodepointBitmapError!c_int {
    if (value > maxCIntValue()) return error.DimensionTooLarge;
    return @intCast(value);
}

fn maxCIntValue() comptime_int {
    return (@as(comptime_int, 1) << (@typeInfo(c_int).int.bits - 1)) - 1;
}

pub fn TestRunner(comptime lib: type, comptime font_bytes: []const u8) @import("testing").TestRunner {
    const embed = @import("embed");
    const testing_api = @import("testing");

    const Runner = struct {
        const testing = lib.testing;
        const embedded_codepoint: u21 = 0x4E2D;

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            runRejectsInvalidInputs() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            runInitOffsetAcceptsValidFontAtZeroOffset() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            runInitOffsetRejectsOffsetsTooLargeForCInt() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            runRenderCodepointBitmapValidatesLayout() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            runRenderCodepointBitmapTreatsZeroSizedRendersAsNoop() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            runRenderCodepointBitmapReportsSizeLimitErrors() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }

        fn runRejectsInvalidInputs() !void {
            const empty = [_]u8{};
            const invalid = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
            const ascii_noise = [_]u8{ 'n', 'o', 't', '-', 'a', '-', 'f', 'o', 'n', 't' };

            try testing.expectError(InitError.InvalidFont, Self.init(empty[0..]));
            try testing.expectError(InitError.InvalidFont, Self.init(invalid[0..]));
            try testing.expectError(InitError.InvalidFont, Self.init(ascii_noise[0..]));
            try testing.expectError(InitError.InvalidFont, Self.initOffset(invalid[0..], 2));
            try testing.expectError(InitError.InvalidFont, Self.initOffset(ascii_noise[0..], ascii_noise.len));
        }

        fn runInitOffsetAcceptsValidFontAtZeroOffset() !void {
            const font = try Self.initOffset(font_bytes, 0);

            try testing.expect(font.glyphIndex(embedded_codepoint) > 0);
        }

        fn runInitOffsetRejectsOffsetsTooLargeForCInt() !void {
            try testing.expectError(
                InitError.OffsetTooLarge,
                intCastFontOffset(@as(usize, maxCIntValue()) + 1),
            );
        }

        fn runRenderCodepointBitmapValidatesLayout() !void {
            const font = try Self.init(font_bytes);
            const scale = font.scaleForPixelHeight(24.0);
            const glyph_box = font.bitmapBox(embedded_codepoint, scale, scale);
            const width: usize = @intCast(glyph_box.width());
            const height: usize = @intCast(glyph_box.height());

            try testing.expect(width > 0);
            try testing.expect(height > 0);

            var invalid_stride_bitmap = [_]u8{0} ** 4;
            try testing.expectError(
                RenderCodepointBitmapError.InvalidStride,
                font.renderCodepointBitmap(
                    invalid_stride_bitmap[0..],
                    width,
                    height,
                    width - 1,
                    scale,
                    scale,
                    embedded_codepoint,
                ),
            );

            const stride = width + 3;
            const required_len = try requiredBitmapLen(width, height, stride);
            try testing.expect(required_len > 0);

            const too_small_bitmap = try testing.allocator.alloc(u8, required_len - 1);
            defer testing.allocator.free(too_small_bitmap);

            try testing.expectError(
                RenderCodepointBitmapError.BufferTooSmall,
                font.renderCodepointBitmap(
                    too_small_bitmap,
                    width,
                    height,
                    stride,
                    scale,
                    scale,
                    embedded_codepoint,
                ),
            );
        }

        fn runRenderCodepointBitmapTreatsZeroSizedRendersAsNoop() !void {
            const font = try Self.init(font_bytes);
            const empty = [_]u8{};

            try font.renderCodepointBitmap(empty[0..], 0, 1, 0, 1.0, 1.0, embedded_codepoint);
            try font.renderCodepointBitmap(empty[0..], 1, 0, 1, 1.0, 1.0, embedded_codepoint);
        }

        fn runRenderCodepointBitmapReportsSizeLimitErrors() !void {
            const max_usize = lib.math.maxInt(usize);

            try testing.expectError(
                RenderCodepointBitmapError.DimensionTooLarge,
                intCastBitmapDimension(@as(usize, maxCIntValue()) + 1),
            );
            try testing.expectError(
                RenderCodepointBitmapError.BitmapTooLarge,
                requiredBitmapLen(1, 2, max_usize),
            );
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
