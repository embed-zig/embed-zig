const embed = @import("embed");

const DisplayApi = embed.drivers.Display;
const Rgb = DisplayApi.Rgb;

const width_px: u16 = 320;
const height_px: u16 = 240;
const chunk_rows: u16 = 10;
const max_chunk_pixels = @as(usize, width_px) * @as(usize, chunk_rows);
const esp_ok: c_int = 0;

const NativeDisplay = struct {
    initialized: bool = false,
    rgb565_buffer: [max_chunk_pixels]u16 = undefined,

    fn init(self: *NativeDisplay) !void {
        try checkNative(szp_display_native_init());
        self.initialized = true;
    }

    fn deinit(self: *NativeDisplay) void {
        self.initialized = false;
    }

    fn width(self: *NativeDisplay) u16 {
        _ = self;
        return width_px;
    }

    fn height(self: *NativeDisplay) u16 {
        _ = self;
        return height_px;
    }

    fn drawBitmap(
        self: *NativeDisplay,
        x: u16,
        y: u16,
        w: u16,
        h: u16,
        pixels: []const Rgb,
    ) DisplayApi.Error!void {
        if (!self.initialized) {
            self.init() catch return error.DisplayError;
        }
        if (w > width_px or pixels.len < @as(usize, w) * @as(usize, h)) return error.OutOfBounds;

        var row: u16 = 0;
        var offset: usize = 0;
        while (row < h) {
            const remaining = h - row;
            const rows = if (remaining > chunk_rows) chunk_rows else remaining;
            const count = @as(usize, w) * @as(usize, rows);

            for (0..count) |index| {
                self.rgb565_buffer[index] = toPanelRgb565(pixels[offset + index]);
            }
            checkNative(szp_display_native_draw_rgb565(
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
};

var native_display = NativeDisplay{};

pub fn init() !void {
    try native_display.init();
}

pub fn driver() DisplayApi {
    return .{
        .ptr = &native_display,
        .vtable = &display_vtable,
    };
}

fn toPanelRgb565(color: Rgb) u16 {
    const value = (@as(u16, color.r & 0xf8) << 8) |
        (@as(u16, color.g & 0xfc) << 3) |
        (@as(u16, color.b) >> 3);
    return (value << 8) | (value >> 8);
}

fn checkNative(rc: c_int) !void {
    if (rc == esp_ok) return;
    return error.DisplayError;
}

fn displayDeinit(ptr: *anyopaque) void {
    const self: *NativeDisplay = @ptrCast(@alignCast(ptr));
    self.deinit();
}

fn displayWidth(ptr: *anyopaque) u16 {
    const self: *NativeDisplay = @ptrCast(@alignCast(ptr));
    return self.width();
}

fn displayHeight(ptr: *anyopaque) u16 {
    const self: *NativeDisplay = @ptrCast(@alignCast(ptr));
    return self.height();
}

fn displayDrawBitmap(
    ptr: *anyopaque,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: []const Rgb,
) DisplayApi.Error!void {
    const self: *NativeDisplay = @ptrCast(@alignCast(ptr));
    return self.drawBitmap(x, y, w, h, pixels);
}

const display_vtable = DisplayApi.VTable{
    .deinit = displayDeinit,
    .width = displayWidth,
    .height = displayHeight,
    .drawBitmap = displayDrawBitmap,
};

extern fn szp_display_native_init() c_int;
extern fn szp_display_native_draw_rgb565(
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: [*]const u16,
    len: usize,
) c_int;
