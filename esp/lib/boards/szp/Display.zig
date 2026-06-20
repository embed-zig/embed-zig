const embed = @import("embed_core");
const esp = @import("esp");

const EspDisplay = @import("../../embed/display.zig");
const binding = @import("bindings/common.zig");

const Display = @This();
const St7789 = embed.drivers.Display.St7789;

const panel_config = St7789.Config{
    .width = 320,
    .height = 240,
    .orientation = .{
        .swap_xy = true,
        .mirror_x = true,
    },
    .pixel_format = .rgb565,
    .data_endian = .big,
    .invert_color = true,
};
const width_px: u16 = panel_config.width;
const height_px: u16 = panel_config.height;
const max_native_flush_rows: u16 = 10;
const dma_allocator = esp.heap.Allocator(.{ .caps = .internal_dma_8bit, .alignment = .align_u32 });

const DelayImpl = struct {
    pub fn sleep(_: *DelayImpl, duration: esp.grt.time.duration.Duration) void {
        if (duration <= 0) return;
        esp.grt.time.sleep(duration);
    }
};

pub const Config = struct {
    max_flush_rows: u16 = 10,
};

config: Config = .{},
native_dbi: EspDisplay.NativeDbi = undefined,
delay: DelayImpl = .{},
display: ?embed.drivers.Display = null,

pub fn init(self: *Display) !void {
    if (self.display != null) return;

    try checkNative(binding.szp_display_native_init());
    const panel_io = binding.szp_display_native_panel_io() orelse return error.DisplayError;
    self.native_dbi = EspDisplay.NativeDbi.init(.{
        .panel_io = panel_io,
    });
    self.delay = .{};

    self.display = try St7789.display(.{
        .allocator = dma_allocator,
        .dbi = self.native_dbi.handle(),
        .delay = embed.drivers.Delay.init(&self.delay),
        .controller = panel_config,
        .flush = self.flushConfig(),
        .open = openController,
        .set_brightness = setBrightness,
    });
}

pub fn deinit(self: *Display) void {
    if (self.display) |display| {
        display.deinit();
        self.display = null;
    }
}

pub fn handle(self: *Display) embed.drivers.Display {
    return self.display.?;
}

fn flushConfig(self: *Display) embed.drivers.Display.Flush.Config {
    return defaultFlushConfig(self.config);
}

fn defaultFlushConfig(config: Config) embed.drivers.Display.Flush.Config {
    const rows = if (config.max_flush_rows == 0)
        1
    else if (config.max_flush_rows > max_native_flush_rows)
        max_native_flush_rows
    else
        config.max_flush_rows;
    return .{
        .native_width = width_px,
        .native_height = height_px,
        .logical_width = width_px,
        .logical_height = height_px,
        .max_flush_rows = rows,
        .rgb565_byte_order = .swapped,
    };
}

fn openController(controller: *St7789) embed.drivers.Display.Error!void {
    try checkNative(binding.szp_pca9557_set_lcd_cs(true));
    controller.softwareReset() catch return error.DisplayError;
    try checkNative(binding.szp_pca9557_set_lcd_cs(false));
    controller.open() catch return error.DisplayError;
}

fn setBrightness(level: u8) embed.drivers.Display.Error!void {
    try checkNative(binding.szp_display_native_set_brightness(level));
}

fn checkNative(rc: c_int) embed.drivers.Display.Error!void {
    if (rc == binding.esp_ok) return;
    return error.DisplayError;
}
