//! Image — Raw Pixel Data for Blitting
//!
//! Describes a rectangular block of pixel data that can be blitted
//! onto a Framebuffer. The pixel format should match the target
//! framebuffer's ColorFormat.
//!
//! Image does not own its data — it references external storage
//! (e.g., @embedFile, flash, or heap-allocated bitmap).

/// Raw image descriptor.
pub const Image = struct {
    width: u16,
    height: u16,
    /// Raw pixel data. Layout: row-major, tightly packed.
    /// For RGB565: 2 bytes per pixel (little-endian u16).
    /// For ARGB8888: 4 bytes per pixel.
    data: []const u8,
    bytes_per_pixel: u8,

    pub fn getPixel(self: *const Image, x: u16, y: u16) u32 {
        if (x >= self.width or y >= self.height) return 0;
        const bpp = @as(usize, self.bytes_per_pixel);
        const offset = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * bpp;
        if (offset + bpp > self.data.len) return 0;

        return switch (self.bytes_per_pixel) {
            2 => @as(u32, self.data[offset]) | (@as(u32, self.data[offset + 1]) << 8),
            3 => @as(u32, self.data[offset]) |
                (@as(u32, self.data[offset + 1]) << 8) |
                (@as(u32, self.data[offset + 2]) << 16),
            4 => @as(u32, self.data[offset]) |
                (@as(u32, self.data[offset + 1]) << 8) |
                (@as(u32, self.data[offset + 2]) << 16) |
                (@as(u32, self.data[offset + 3]) << 24),
            else => 0,
        };
    }

    /// Get a pixel value cast to the framebuffer's Color type.
    pub fn getPixelTyped(self: *const Image, comptime Color: type, x: u16, y: u16) Color {
        const raw = self.getPixel(x, y);
        return @truncate(raw);
    }

    pub fn dataSize(self: *const Image) usize {
        return @as(usize, self.width) * @as(usize, self.height) * @as(usize, self.bytes_per_pixel);
    }
};
