const c = @cImport({
    @cInclude("stb_truetype.h");
});

pub const FontInfo = c.stbtt_fontinfo;

pub const stbtt_InitFont = c.stbtt_InitFont;
pub const stbtt_ScaleForPixelHeight = c.stbtt_ScaleForPixelHeight;
pub const stbtt_ScaleForMappingEmToPixels = c.stbtt_ScaleForMappingEmToPixels;
pub const stbtt_GetFontVMetrics = c.stbtt_GetFontVMetrics;
pub const stbtt_GetCodepointHMetrics = c.stbtt_GetCodepointHMetrics;
pub const stbtt_GetCodepointKernAdvance = c.stbtt_GetCodepointKernAdvance;
pub const stbtt_GetCodepointBitmapBox = c.stbtt_GetCodepointBitmapBox;
pub const stbtt_MakeCodepointBitmap = c.stbtt_MakeCodepointBitmap;
pub const stbtt_FindGlyphIndex = c.stbtt_FindGlyphIndex;

test "stb_truetype/unit_tests/binding/exports_core_stb_symbols" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expect(@sizeOf(FontInfo) > 0);

    _ = stbtt_InitFont;
    _ = stbtt_ScaleForPixelHeight;
    _ = stbtt_GetCodepointBitmapBox;
}
