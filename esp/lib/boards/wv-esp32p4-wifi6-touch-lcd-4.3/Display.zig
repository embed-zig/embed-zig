const embed = @import("embed_core");
const esp = @import("esp");

const EspDisplay = @import("../../embed/display.zig");
const binding = @import("bindings/common.zig");

const Display = @This();
const St7701 = embed.drivers.Display.St7701;

const panel_config = St7701.defaultWaveshareP443Config();
const width_px: u16 = panel_config.width;
const height_px: u16 = panel_config.height;
const dma_allocator = esp.heap.Allocator(.{ .caps = .internal_dma_8bit, .alignment = .align_u32 });

const DelayImpl = struct {
    pub fn sleep(_: *DelayImpl, duration: esp.grt.time.duration.Duration) void {
        if (duration <= 0) return;
        esp.grt.std.Thread.sleep(@intCast(duration));
    }
};

pub const Config = struct {
    max_flush_rows: u16 = 16,
};

config: Config = .{},
native_dbi: EspDisplay.NativeDbi = undefined,
delay: DelayImpl = .{},
display: ?embed.drivers.Display = null,

pub fn init(self: *Display) !void {
    if (self.display != null) return;

    try checkNative(binding.wv_p4_display_native_init());
    const panel_io = binding.wv_p4_display_native_panel_io() orelse return error.DisplayError;
    self.native_dbi = EspDisplay.NativeDbi.init(.{
        .panel_io = panel_io,
    });
    self.delay = .{};

    self.display = try St7701.display(.{
        .allocator = dma_allocator,
        .dbi = self.native_dbi.handle(),
        .delay = embed.drivers.Delay.init(&self.delay),
        .controller = panel_config,
        .flush = self.flushConfig(),
        .open = openController,
        .set_brightness = setBrightness,
        .flush_rgb565 = flushRgb565,
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
    return .{
        .native_width = width_px,
        .native_height = height_px,
        .logical_width = width_px,
        .logical_height = height_px,
        .max_flush_rows = config.max_flush_rows,
        .rgb565_byte_order = .native,
    };
}

fn openController(controller: *St7701) embed.drivers.Display.Error!void {
    try checkNative(binding.wv_p4_display_native_reset_panel());
    controller.open() catch return error.DisplayError;
    try checkNative(binding.wv_p4_display_native_start_panel());
}

fn setBrightness(level: u8) embed.drivers.Display.Error!void {
    try checkNative(binding.wv_p4_display_native_set_brightness(level));
}

fn flushRgb565(x: u16, y: u16, w: u16, h: u16, pixels: []const u16) embed.drivers.Display.Error!void {
    try checkNative(binding.wv_p4_display_native_flush_rgb565(
        x,
        y,
        w,
        h,
        pixels.ptr,
        pixels.len,
    ));
}

fn checkNative(rc: c_int) embed.drivers.Display.Error!void {
    if (rc == binding.esp_ok) return;
    return error.DisplayError;
}
