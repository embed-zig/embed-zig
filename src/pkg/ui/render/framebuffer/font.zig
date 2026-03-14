//! Bitmap Font — Dynamic Font System
//!
//! Supports any character set (ASCII, CJK, etc.) via a lookup function
//! pointer that maps Unicode codepoints to glyph indices.
//!
//! Font data is external — can be @embedFile'd at compile time,
//! loaded from flash, or generated at runtime. The BitmapFont struct
//! just references the data; it owns nothing.
//!
//! Glyph format: 1 bit per pixel, row-major, MSB first.
//! Each row is ceil(glyph_w / 8) bytes. Total per glyph:
//!   ceil(glyph_w / 8) * glyph_h bytes.

/// Bitmap font descriptor.
///
/// All fields are set by the caller — the font system imposes no
/// constraints on character set, size, or data source.
pub const BitmapFont = struct {
    glyph_w: u8,
    glyph_h: u8,
    data: []const u8,
    lookup: *const fn (u21) ?u32,

    pub fn bytesPerRow(self: *const BitmapFont) usize {
        return (@as(usize, self.glyph_w) + 7) / 8;
    }

    pub fn glyphSize(self: *const BitmapFont) usize {
        return self.bytesPerRow() * @as(usize, self.glyph_h);
    }

    pub fn getGlyph(self: *const BitmapFont, codepoint: u21) ?[]const u8 {
        const idx = self.lookup(codepoint) orelse return null;
        const size = self.glyphSize();
        const start = @as(usize, idx) * size;
        if (start + size > self.data.len) return null;
        return self.data[start..][0..size];
    }

    pub fn textWidth(self: *const BitmapFont, text: []const u8) u16 {
        var width: u16 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const decoded = decodeUtf8(text[i..]);
            i += decoded.len;
            if (decoded.codepoint) |cp| {
                if (self.lookup(cp) != null) {
                    width += self.glyph_w;
                }
            }
        }
        return width;
    }
};

/// Create a lookup function for a contiguous ASCII range.
///
/// Example: `asciiLookup(32, 95)` covers space (0x20) through tilde (0x7E).
pub fn asciiLookup(comptime first: u8, comptime count: u16) *const fn (u21) ?u32 {
    const S = struct {
        fn lookup(cp: u21) ?u32 {
            if (cp < first or cp >= @as(u21, first) + count) return null;
            return @intCast(cp - first);
        }
    };
    return &S.lookup;
}

// ============================================================================
// UTF-8 Decoding
// ============================================================================

pub const Utf8Result = struct {
    codepoint: ?u21,
    len: usize,
};

/// Decode one UTF-8 codepoint from the start of `bytes`.
///
/// Returns the codepoint and the number of bytes consumed.
/// On invalid UTF-8, returns null codepoint and advances 1 byte.
pub fn decodeUtf8(bytes: []const u8) Utf8Result {
    if (bytes.len == 0) return .{ .codepoint = null, .len = 0 };

    const b0 = bytes[0];

    if (b0 < 0x80) {
        return .{ .codepoint = b0, .len = 1 };
    }

    const seq_len: usize, const initial: u21 = if (b0 & 0xE0 == 0xC0)
        .{ 2, b0 & 0x1F }
    else if (b0 & 0xF0 == 0xE0)
        .{ 3, b0 & 0x0F }
    else if (b0 & 0xF8 == 0xF0)
        .{ 4, b0 & 0x07 }
    else
        return .{ .codepoint = null, .len = 1 };

    if (bytes.len < seq_len) return .{ .codepoint = null, .len = 1 };

    var cp: u21 = initial;
    for (1..seq_len) |i| {
        const b = bytes[i];
        if (b & 0xC0 != 0x80) return .{ .codepoint = null, .len = 1 };
        cp = (cp << 6) | (b & 0x3F);
    }

    return .{ .codepoint = cp, .len = seq_len };
}
