const embed = @import("embed_core");
const binding = @import("bindings/common.zig");

const Display = @This();

const native_width_px: u16 = 368;
const native_height_px: u16 = 448;
const width_px: u16 = native_height_px;
const height_px: u16 = native_width_px;
const chunk_rows: u16 = 8;
const max_chunk_pixels = @as(usize, width_px) * @as(usize, chunk_rows);

initialized: bool = false,
enabled: bool = true,
brightness: u8 = 255,
rgb565_buffer: [max_chunk_pixels]u16 = undefined,

pub fn init(self: *Display) !void {
    try checkNative(binding.wv_display_native_init());
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

fn setEnabled(self: *Display, enabled: bool) embed.drivers.Display.Error!void {
    if (!self.initialized) {
        self.init() catch return error.DisplayError;
    }
    checkNative(binding.wv_display_native_set_enabled(enabled)) catch return error.DisplayError;
    self.enabled = enabled;
}

fn getEnabled(self: *Display) embed.drivers.Display.Error!bool {
    return self.enabled;
}

fn setBrightness(self: *Display, brightness: u8) embed.drivers.Display.Error!void {
    if (!self.initialized) {
        self.init() catch return error.DisplayError;
    }
    checkNative(binding.wv_display_native_set_brightness(brightness)) catch return error.DisplayError;
    self.brightness = brightness;
}

fn getBrightness(self: *Display) embed.drivers.Display.Error!u8 {
    return self.brightness;
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

        for (0..w) |dst_y| {
            const src_x = @as(usize, w) - 1 - dst_y;
            for (0..rows) |dst_x| {
                const src_y = dst_x;
                self.rgb565_buffer[dst_y * @as(usize, rows) + dst_x] =
                    toPanelRgb565(pixels[offset + src_y * @as(usize, w) + src_x]);
            }
        }
        checkNative(binding.wv_display_native_draw_rgb565(
            y + row,
            native_height_px - x - w,
            rows,
            w,
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

fn displaySetEnabled(ptr: *anyopaque, enabled: bool) embed.drivers.Display.Error!void {
    const self: *Display = @ptrCast(@alignCast(ptr));
    return self.setEnabled(enabled);
}

fn displayGetEnabled(ptr: *anyopaque) embed.drivers.Display.Error!bool {
    const self: *Display = @ptrCast(@alignCast(ptr));
    return self.getEnabled();
}

fn displaySetBrightness(ptr: *anyopaque, brightness: u8) embed.drivers.Display.Error!void {
    const self: *Display = @ptrCast(@alignCast(ptr));
    return self.setBrightness(brightness);
}

fn displayGetBrightness(ptr: *anyopaque) embed.drivers.Display.Error!u8 {
    const self: *Display = @ptrCast(@alignCast(ptr));
    return self.getBrightness();
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
    .setEnabled = displaySetEnabled,
    .getEnabled = displayGetEnabled,
    .setBrightness = displaySetBrightness,
    .getBrightness = displayGetBrightness,
    .drawBitmap = displayDrawBitmap,
};
