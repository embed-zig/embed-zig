const std = @import("std");
const esp = @import("esp");
const hal_display = @import("hal").display;

pub const Driver = struct {
    bus: esp.esp_lcd.spi.Bus,
    io: esp.esp_lcd.spi.PanelIo,
    panel: esp.esp_lcd.Panel,
    width_px: u16,
    height_px: u16,
    framebuffer: []hal_display.Color565,
    allocator: std.mem.Allocator,

    pub const PanelKind = enum {
        st7789,
        ili9341,
    };

    pub const Config = struct {
        panel: PanelKind = .st7789,
        width: u16 = 240,
        height: u16 = 240,

        host_id: i32 = 2,
        sclk: i32 = 18,
        mosi: i32 = 23,
        miso: i32 = -1,
        cs: i32 = 5,
        dc: i32 = 21,
        reset: i32 = -1,

        pclk_hz: u32 = 20_000_000,
        spi_mode: u8 = 0,
        max_transfer_bytes: usize = 4096,
        dma_channel: i32 = -1,
        cmd_bits: u8 = 8,
        param_bits: u8 = 8,
        trans_queue_depth: u32 = 10,

        allocator: std.mem.Allocator = std.heap.c_allocator,
    };

    pub fn init(cfg: Config) hal_display.Error!Driver {
        if (cfg.width == 0 or cfg.height == 0) return error.DisplayError;

        var bus = esp.esp_lcd.spi.Bus.init(.{
            .host_id = cfg.host_id,
            .sclk_io_num = cfg.sclk,
            .mosi_io_num = cfg.mosi,
            .miso_io_num = cfg.miso,
            .max_transfer_bytes = cfg.max_transfer_bytes,
            .dma_channel = cfg.dma_channel,
        }) catch return error.DisplayError;
        errdefer bus.deinit() catch {};

        var io = esp.esp_lcd.spi.PanelIo.init(&bus, .{
            .cs_io_num = cfg.cs,
            .dc_io_num = cfg.dc,
            .pclk_hz = cfg.pclk_hz,
            .spi_mode = cfg.spi_mode,
            .cmd_bits = cfg.cmd_bits,
            .param_bits = cfg.param_bits,
            .trans_queue_depth = cfg.trans_queue_depth,
        }) catch return error.DisplayError;
        errdefer io.deinit() catch {};

        var panel = switch (cfg.panel) {
            .st7789 => esp.esp_lcd.driver.create(esp.esp_lcd.driver.st7789, &io, .{
                .reset_gpio_num = cfg.reset,
                .bits_per_pixel = 16,
            }) catch return error.DisplayError,
            .ili9341 => esp.esp_lcd.driver.create(esp.esp_lcd.driver.ili9341, &io, .{
                .reset_gpio_num = cfg.reset,
                .bits_per_pixel = 16,
            }) catch return error.DisplayError,
        };
        errdefer panel.deinit() catch {};

        panel.reset() catch return error.DisplayError;
        panel.init() catch return error.DisplayError;
        panel.setDisplayEnabled(true) catch return error.DisplayError;

        const pixel_count = @as(usize, cfg.width) * @as(usize, cfg.height);
        const framebuffer = cfg.allocator.alloc(hal_display.Color565, pixel_count) catch return error.DisplayError;
        @memset(framebuffer, 0);

        return .{
            .bus = bus,
            .io = io,
            .panel = panel,
            .width_px = cfg.width,
            .height_px = cfg.height,
            .framebuffer = framebuffer,
            .allocator = cfg.allocator,
        };
    }

    pub fn deinit(self: *Driver) void {
        self.panel.deinit() catch {};
        self.io.deinit() catch {};
        self.bus.deinit() catch {};
        self.allocator.free(self.framebuffer);
        self.framebuffer = &.{};
    }

    pub fn width(self: *const Driver) u16 {
        return self.width_px;
    }

    pub fn height(self: *const Driver) u16 {
        return self.height_px;
    }

    pub fn drawPixel(self: *Driver, x: u16, y: u16, color: hal_display.Color565) hal_display.Error!void {
        if (x >= self.width_px or y >= self.height_px) return error.OutOfBounds;
        const idx = @as(usize, y) * @as(usize, self.width_px) + @as(usize, x);
        self.framebuffer[idx] = color;
    }

    pub fn clear(self: *Driver, color: hal_display.Color565) hal_display.Error!void {
        @memset(self.framebuffer, color);
    }

    pub fn flush(self: *Driver) hal_display.Error!void {
        self.panel.drawBitmap(
            0,
            0,
            self.width_px,
            self.height_px,
            @ptrCast(self.framebuffer.ptr),
        ) catch return error.DisplayError;
    }
};
