//! Animation Player — decodes and plays .anim frame-diff files
//!
//! Format (produced by tools/mp4todiff):
//!   Header (14 bytes):
//!     [0:2]   u16 LE  display_width (original size, e.g. 240)
//!     [2:4]   u16 LE  display_height
//!     [4:6]   u16 LE  frame_width (scaled, e.g. 120)
//!     [6:8]   u16 LE  frame_height
//!     [8:10]  u16 LE  frame_count
//!     [10]    u8      fps
//!     [11]    u8      scale factor (e.g. 2 = each pixel drawn as 2x2)
//!     [12:14] u16 LE  palette_size
//!   Palette: palette_size × 2 bytes (RGB565 LE)
//!   Per frame:
//!     [+0]    u16 LE  rect_count
//!     Per rect:
//!       [+0]  u16 LE  x, y, w, h (in frame coords)
//!       [+8]  RLE data: [count-1 (u8)] [palette_index (u8)] pairs

const framebuffer_mod = @import("framebuffer.zig");

pub const AnimHeader = struct {
    display_w: u16,
    display_h: u16,
    frame_w: u16,
    frame_h: u16,
    frame_count: u16,
    fps: u8,
    scale: u8,
    palette_size: u16,
};

pub const AnimRect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: []const u16,
};

const MAX_RECTS = 192;
const MAX_FRAME_PIXELS = 160 * 160;

pub const AnimFrame = struct {
    rects: []const AnimRect,
    frame_index: u16,
};

/// Animation player — streams through .anim data one frame at a time.
/// Zero-alloc: uses internal fixed buffers for decode.
pub const AnimPlayer = struct {
    const Self = @This();

    data: []const u8,
    header: AnimHeader,
    palette: []const u8,
    pos: usize,
    frame_index: u16,

    rect_buf: [MAX_RECTS]AnimRect = undefined,
    pixel_buf: [MAX_FRAME_PIXELS]u16 = undefined,

    pub fn init(anim_data: []const u8) ?Self {
        if (anim_data.len < 14) return null;

        const h = AnimHeader{
            .display_w = readU16(anim_data, 0),
            .display_h = readU16(anim_data, 2),
            .frame_w = readU16(anim_data, 4),
            .frame_h = readU16(anim_data, 6),
            .frame_count = readU16(anim_data, 8),
            .fps = anim_data[10],
            .scale = anim_data[11],
            .palette_size = readU16(anim_data, 12),
        };

        const palette_bytes = @as(usize, h.palette_size) * 2;
        if (anim_data.len < 14 + palette_bytes) return null;

        return Self{
            .data = anim_data,
            .header = h,
            .palette = anim_data[14..][0..palette_bytes],
            .pos = 14 + palette_bytes,
            .frame_index = 0,
        };
    }

    pub fn nextFrame(self: *Self) ?AnimFrame {
        if (self.frame_index >= self.header.frame_count) return null;
        if (self.pos + 2 > self.data.len) return null;

        const rect_count = readU16(self.data, self.pos);
        self.pos += 2;

        if (rect_count > MAX_RECTS) return null;

        var pixel_offset: usize = 0;

        for (0..rect_count) |i| {
            if (self.pos + 8 > self.data.len) return null;

            const rx = readU16(self.data, self.pos);
            const ry = readU16(self.data, self.pos + 2);
            const rw = readU16(self.data, self.pos + 4);
            const rh = readU16(self.data, self.pos + 6);
            self.pos += 8;

            const pixel_count = @as(usize, rw) * @as(usize, rh);
            if (pixel_offset + pixel_count > MAX_FRAME_PIXELS) return null;

            var decoded: usize = 0;
            while (decoded < pixel_count) {
                if (self.pos + 2 > self.data.len) return null;
                const run_len = @as(usize, self.data[self.pos]) + 1;
                const pal_idx = self.data[self.pos + 1];
                self.pos += 2;

                const color = paletteColor(self.palette, pal_idx);

                const actual = @min(run_len, pixel_count - decoded);
                @memset(self.pixel_buf[pixel_offset + decoded ..][0..actual], color);
                decoded += actual;
            }

            self.rect_buf[i] = AnimRect{
                .x = rx,
                .y = ry,
                .w = rw,
                .h = rh,
                .pixels = self.pixel_buf[pixel_offset..][0..pixel_count],
            };
            pixel_offset += pixel_count;
        }

        const frame = AnimFrame{
            .rects = self.rect_buf[0..rect_count],
            .frame_index = self.frame_index,
        };
        self.frame_index += 1;
        return frame;
    }

    pub fn reset(self: *Self) void {
        self.pos = 14 + @as(usize, self.header.palette_size) * 2;
        self.frame_index = 0;
    }

    pub fn frameDurationMs(self: *const Self) u32 {
        if (self.header.fps == 0) return 33;
        return 1000 / @as(u32, self.header.fps);
    }

    pub fn isDone(self: *const Self) bool {
        return self.frame_index >= self.header.frame_count;
    }
};

/// Blit an animation frame to a Framebuffer, applying scale factor.
pub fn blitAnimFrame(
    comptime W: u16,
    comptime H: u16,
    comptime fmt: framebuffer_mod.ColorFormat,
    fb: *framebuffer_mod.Framebuffer(W, H, fmt),
    frame: AnimFrame,
    scale: u8,
) void {
    for (frame.rects) |rect| {
        if (scale == 1) {
            var row: u16 = 0;
            while (row < rect.h) : (row += 1) {
                var col: u16 = 0;
                while (col < rect.w) : (col += 1) {
                    const px = rect.pixels[@as(usize, row) * rect.w + @as(usize, col)];
                    fb.setPixel(rect.x + col, rect.y + row, px);
                }
            }
        } else {
            const s: u16 = scale;
            var row: u16 = 0;
            while (row < rect.h) : (row += 1) {
                var col: u16 = 0;
                while (col < rect.w) : (col += 1) {
                    const px = rect.pixels[@as(usize, row) * rect.w + @as(usize, col)];
                    const dx: u32 = @as(u32, rect.x) * s + @as(u32, col) * s;
                    const dy: u32 = @as(u32, rect.y) * s + @as(u32, row) * s;
                    if (dx > 0xFFFF or dy > 0xFFFF) continue;
                    fb.fillRect(@intCast(dx), @intCast(dy), s, s, px);
                }
            }
        }
    }
}

fn readU16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn paletteColor(palette: []const u8, idx: u8) u16 {
    const offset = @as(usize, idx) * 2;
    if (offset + 2 > palette.len) return 0;
    return @as(u16, palette[offset]) | (@as(u16, palette[offset + 1]) << 8);
}
