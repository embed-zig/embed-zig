const embed = @import("embed");
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
};

pub fn init(data: []const u8) InitError!Self {
    return initOffset(data, 0);
}

pub fn initOffset(data: []const u8, offset: usize) InitError!Self {
    const min_font_header_len = 12;
    if (offset > data.len or data.len - offset < min_font_header_len) {
        return error.InvalidFont;
    }

    var self: Self = .{
        .info = undefined,
        .data = data,
    };
    if (binding.stbtt_InitFont(&self.info, data.ptr, @intCast(offset)) == 0) {
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
) void {
    binding.stbtt_MakeCodepointBitmap(
        &self.info,
        output.ptr,
        @intCast(width),
        @intCast(height),
        @intCast(stride),
        scale_x,
        scale_y,
        @intCast(codepoint),
    );
}

pub fn glyphIndex(self: *const Self, codepoint: u21) i32 {
    return binding.stbtt_FindGlyphIndex(&self.info, @intCast(codepoint));
}

test "stb_truetype/unit_tests/Font/rejects_invalid_inputs" {
    const std = @import("std");
    const testing = std.testing;

    const empty = [_]u8{};
    const invalid = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    const ascii_noise = [_]u8{ 'n', 'o', 't', '-', 'a', '-', 'f', 'o', 'n', 't' };

    try testing.expectError(InitError.InvalidFont, Self.init(empty[0..]));
    try testing.expectError(InitError.InvalidFont, Self.init(invalid[0..]));
    try testing.expectError(InitError.InvalidFont, Self.init(ascii_noise[0..]));
    try testing.expectError(InitError.InvalidFont, Self.initOffset(invalid[0..], 2));
    try testing.expectError(InitError.InvalidFont, Self.initOffset(ascii_noise[0..], ascii_noise.len));
}
