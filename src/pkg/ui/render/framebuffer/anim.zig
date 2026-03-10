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

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "AnimPlayer: parse header" {
    var data: [14 + 4 + 2 + 8 + 2]u8 = undefined;
    data[0] = 2;
    data[1] = 0;
    data[2] = 2;
    data[3] = 0;
    data[4] = 1;
    data[5] = 0;
    data[6] = 1;
    data[7] = 0;
    data[8] = 1;
    data[9] = 0;
    data[10] = 15;
    data[11] = 2;
    data[12] = 2;
    data[13] = 0;
    data[14] = 0;
    data[15] = 0;
    data[16] = 0xFF;
    data[17] = 0xFF;
    data[18] = 1;
    data[19] = 0;
    data[20] = 0;
    data[21] = 0;
    data[22] = 0;
    data[23] = 0;
    data[24] = 1;
    data[25] = 0;
    data[26] = 1;
    data[27] = 0;
    data[28] = 0;
    data[29] = 1;

    var player = AnimPlayer.init(&data) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(u16, 2), player.header.display_w);
    try testing.expectEqual(@as(u16, 1), player.header.frame_w);
    try testing.expectEqual(@as(u16, 1), player.header.frame_count);
    try testing.expectEqual(@as(u8, 15), player.header.fps);
    try testing.expectEqual(@as(u8, 2), player.header.scale);

    const frame = player.nextFrame() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), frame.rects.len);
    try testing.expectEqual(@as(u16, 0xFFFF), frame.rects[0].pixels[0]);

    try testing.expectEqual(@as(?AnimFrame, null), player.nextFrame());
    try testing.expect(player.isDone());
}

test "AnimPlayer: RLE decode multiple runs" {
    var data: [14 + 4 + 2 + 8 + 4]u8 = undefined;
    data[0] = 4;
    data[1] = 0;
    data[2] = 1;
    data[3] = 0;
    data[4] = 4;
    data[5] = 0;
    data[6] = 1;
    data[7] = 0;
    data[8] = 1;
    data[9] = 0;
    data[10] = 30;
    data[11] = 1;
    data[12] = 2;
    data[13] = 0;
    data[14] = 0;
    data[15] = 0;
    data[16] = 0xFF;
    data[17] = 0xFF;
    data[18] = 1;
    data[19] = 0;
    data[20] = 0;
    data[21] = 0;
    data[22] = 0;
    data[23] = 0;
    data[24] = 4;
    data[25] = 0;
    data[26] = 1;
    data[27] = 0;
    data[28] = 1;
    data[29] = 0;
    data[30] = 1;
    data[31] = 1;

    var player = AnimPlayer.init(&data).?;
    const frame = player.nextFrame().?;

    try testing.expectEqual(@as(u16, 0x0000), frame.rects[0].pixels[0]);
    try testing.expectEqual(@as(u16, 0x0000), frame.rects[0].pixels[1]);
    try testing.expectEqual(@as(u16, 0xFFFF), frame.rects[0].pixels[2]);
    try testing.expectEqual(@as(u16, 0xFFFF), frame.rects[0].pixels[3]);
}

fn buildMultiFrameAnim() [14 + 4 + 3 * (2 + 8 + 2 * 2)]u8 {
    const HEADER = 14;
    const PAL = 4;
    const FRAME = 2 + 8 + 4;
    var d: [HEADER + PAL + 3 * FRAME]u8 = undefined;
    d[0] = 2;
    d[1] = 0;
    d[2] = 1;
    d[3] = 0;
    d[4] = 2;
    d[5] = 0;
    d[6] = 1;
    d[7] = 0;
    d[8] = 3;
    d[9] = 0;
    d[10] = 10;
    d[11] = 1;
    d[12] = 2;
    d[13] = 0;
    d[14] = 0;
    d[15] = 0;
    d[16] = 0xFF;
    d[17] = 0xFF;

    const base = HEADER + PAL;
    inline for (0..3) |f| {
        const off = base + f * FRAME;
        d[off] = 1;
        d[off + 1] = 0;
        d[off + 2] = 0;
        d[off + 3] = 0;
        d[off + 4] = 0;
        d[off + 5] = 0;
        d[off + 6] = 2;
        d[off + 7] = 0;
        d[off + 8] = 1;
        d[off + 9] = 0;
        const colors: [3][2]u8 = .{
            .{ 0, 1 },
            .{ 1, 0 },
            .{ 1, 1 },
        };
        d[off + 10] = 0;
        d[off + 11] = colors[f][0];
        d[off + 12] = 0;
        d[off + 13] = colors[f][1];
    }
    return d;
}

test "T1: multi-frame playback" {
    var data = buildMultiFrameAnim();
    var player = AnimPlayer.init(&data).?;

    try testing.expectEqual(@as(u16, 3), player.header.frame_count);
    try testing.expect(!player.isDone());

    const f0 = player.nextFrame().?;
    try testing.expectEqual(@as(u16, 0), f0.frame_index);
    try testing.expectEqual(@as(u16, 0x0000), f0.rects[0].pixels[0]);
    try testing.expectEqual(@as(u16, 0xFFFF), f0.rects[0].pixels[1]);

    const f1 = player.nextFrame().?;
    try testing.expectEqual(@as(u16, 1), f1.frame_index);
    try testing.expectEqual(@as(u16, 0xFFFF), f1.rects[0].pixels[0]);
    try testing.expectEqual(@as(u16, 0x0000), f1.rects[0].pixels[1]);

    const f2 = player.nextFrame().?;
    try testing.expectEqual(@as(u16, 2), f2.frame_index);
    try testing.expectEqual(@as(u16, 0xFFFF), f2.rects[0].pixels[0]);
    try testing.expectEqual(@as(u16, 0xFFFF), f2.rects[0].pixels[1]);

    try testing.expect(player.nextFrame() == null);
    try testing.expect(player.isDone());
}

test "T2: loop playback — reset replays from frame 0" {
    var data = buildMultiFrameAnim();
    var player = AnimPlayer.init(&data).?;

    _ = player.nextFrame().?;
    _ = player.nextFrame().?;
    _ = player.nextFrame().?;
    try testing.expect(player.isDone());

    player.reset();
    try testing.expect(!player.isDone());
    try testing.expectEqual(@as(u16, 0), player.frame_index);

    const f0 = player.nextFrame().?;
    try testing.expectEqual(@as(u16, 0), f0.frame_index);
    try testing.expectEqual(@as(u16, 0x0000), f0.rects[0].pixels[0]);
    try testing.expectEqual(@as(u16, 0xFFFF), f0.rects[0].pixels[1]);

    const f1 = player.nextFrame().?;
    try testing.expectEqual(@as(u16, 1), f1.frame_index);
}

test "T3: blitAnimFrame writes correct pixels to framebuffer" {
    var data = buildMultiFrameAnim();
    var player = AnimPlayer.init(&data).?;

    const FB = framebuffer_mod.Framebuffer(4, 4, .rgb565);
    var fb = FB.init(0x1234);

    const frame = player.nextFrame().?;
    blitAnimFrame(4, 4, .rgb565, &fb, frame, 1);

    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(0, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(1, 0));
    try testing.expectEqual(@as(u16, 0x1234), fb.getPixel(2, 0));
    try testing.expectEqual(@as(u16, 0x1234), fb.getPixel(0, 1));

    var fb2 = FB.init(0x1234);
    blitAnimFrame(4, 4, .rgb565, &fb2, frame, 2);

    try testing.expectEqual(@as(u16, 0x0000), fb2.getPixel(0, 0));
    try testing.expectEqual(@as(u16, 0x0000), fb2.getPixel(1, 0));
    try testing.expectEqual(@as(u16, 0x0000), fb2.getPixel(0, 1));
    try testing.expectEqual(@as(u16, 0x0000), fb2.getPixel(1, 1));
    try testing.expectEqual(@as(u16, 0xFFFF), fb2.getPixel(2, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), fb2.getPixel(3, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), fb2.getPixel(2, 1));
    try testing.expectEqual(@as(u16, 0xFFFF), fb2.getPixel(3, 1));
}

test "T4: malformed data does not crash" {
    try testing.expect(AnimPlayer.init(&[_]u8{}) == null);
    try testing.expect(AnimPlayer.init(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }) == null);

    var short: [14]u8 = undefined;
    @memset(&short, 0);
    short[12] = 100;
    try testing.expect(AnimPlayer.init(&short) == null);

    var zero_frames: [14 + 4]u8 = undefined;
    @memset(&zero_frames, 0);
    zero_frames[12] = 2;
    zero_frames[14] = 0xAA;
    zero_frames[15] = 0xBB;
    zero_frames[16] = 0xCC;
    zero_frames[17] = 0xDD;
    var player = AnimPlayer.init(&zero_frames).?;
    try testing.expect(player.isDone());
    try testing.expect(player.nextFrame() == null);

    var trunc: [14 + 4 + 2]u8 = undefined;
    @memset(&trunc, 0);
    trunc[8] = 1;
    trunc[12] = 2;
    trunc[18] = 1;
    trunc[19] = 0;
    var player2 = AnimPlayer.init(&trunc).?;
    try testing.expect(player2.nextFrame() == null);
}
