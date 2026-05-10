const embed = @import("embed");
const binding = @import("bindings/common.zig");

const Display = @This();

const width_px: u16 = 320;
const height_px: u16 = 240;
const chunk_rows: u16 = 10;
const max_chunk_pixels = @as(usize, width_px) * @as(usize, chunk_rows);

initialized: bool = false,
rgb565_buffer: [max_chunk_pixels]u16 = undefined,

pub fn init(self: *Display) !void {
    try checkNative(binding.szp_display_native_init());
    self.initialized = true;
}

pub fn deinit(self: *Display) void {
    self.initialized = false;
}

pub fn handle(self: *Display) embed.drivers.Display {
    return .{
        .ptr = self,
        .vtable = &display_vtable,
    };
}

fn width(self: *Display) u16 {
    _ = self;
    return width_px;
}

fn height(self: *Display) u16 {
    _ = self;
    return height_px;
}

fn drawBitmap(
    self: *Display,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: []const embed.drivers.Display.Rgb,
) embed.drivers.Display.Error!void {
    if (!self.initialized) {
        self.init() catch return error.DisplayError;
    }
    if (w == 0 or h == 0) return;

    const x_end = @as(u32, x) + @as(u32, w);
    const y_end = @as(u32, y) + @as(u32, h);
    const pixel_count = @as(usize, w) * @as(usize, h);
    if (x_end > width_px or y_end > height_px or pixels.len < pixel_count) return error.OutOfBounds;

    var row: u16 = 0;
    var offset: usize = 0;
    while (row < h) {
        const remaining = h - row;
        const rows = if (remaining > chunk_rows) chunk_rows else remaining;
        const count = @as(usize, w) * @as(usize, rows);

        for (0..count) |index| {
            self.rgb565_buffer[index] = toPanelRgb565(pixels[offset + index]);
        }
        checkNative(binding.szp_display_native_draw_rgb565(
            x,
            y + row,
            w,
            rows,
            self.rgb565_buffer[0..count].ptr,
            count,
        )) catch return error.DisplayError;

        row += rows;
        offset += count;
    }
}

fn toPanelRgb565(color: embed.drivers.Display.Rgb) u16 {
    const value = (@as(u16, color.r & 0xf8) << 8) |
        (@as(u16, color.g & 0xfc) << 3) |
        (@as(u16, color.b) >> 3);
    return (value << 8) | (value >> 8);
}

fn checkNative(rc: c_int) !void {
    if (rc == binding.esp_ok) return;
    return error.DisplayError;
}

fn displayDeinit(ptr: *anyopaque) void {
    const self: *Display = @ptrCast(@alignCast(ptr));
    self.deinit();
}

fn displayWidth(ptr: *anyopaque) u16 {
    const self: *Display = @ptrCast(@alignCast(ptr));
    return self.width();
}

fn displayHeight(ptr: *anyopaque) u16 {
    const self: *Display = @ptrCast(@alignCast(ptr));
    return self.height();
}

fn displayDrawBitmap(
    ptr: *anyopaque,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: []const embed.drivers.Display.Rgb,
) embed.drivers.Display.Error!void {
    const self: *Display = @ptrCast(@alignCast(ptr));
    return self.drawBitmap(x, y, w, h, pixels);
}

const display_vtable = embed.drivers.Display.VTable{
    .deinit = displayDeinit,
    .width = displayWidth,
    .height = displayHeight,
    .drawBitmap = displayDrawBitmap,
};
