const embed = @import("embed_core");
const esp = @import("esp");

const EspDisplay = @import("../../embed/display.zig");
const binding = @import("bindings/common.zig");

const Display = @This();
const Sh8601 = embed.drivers.Display.Sh8601;

const panel_config = Sh8601.defaultWvAmoled18Config();
const native_width_px: u16 = panel_config.native_width;
const native_height_px: u16 = panel_config.native_height;
const width_px: u16 = panel_config.logical_width;
const height_px: u16 = panel_config.logical_height;
const dma_allocator = esp.heap.Allocator(.{ .caps = .internal_dma_8bit, .alignment = .align_u32 });

const DelayImpl = struct {
    pub fn sleep(_: *DelayImpl, duration: esp.grt.time.duration.Duration) void {
        if (duration <= 0) return;
        esp.grt.time.sleep(duration);
    }
};

pub const Config = struct {
    max_flush_rows: u16 = 8,
};

config: Config = .{},
native_dbi: EspDisplay.NativeDbi = undefined,
delay: DelayImpl = .{},
display: ?embed.drivers.Display = null,

pub fn init(self: *Display) !void {
    if (self.display != null) return;

    try checkNative(binding.wv_display_native_init());
    const panel_io = binding.wv_display_native_panel_io() orelse return error.DisplayError;
    self.native_dbi = EspDisplay.NativeDbi.init(.{
        .panel_io = panel_io,
        .command_encoding = .{
            .qspi = .{
                .write_command_opcode = Sh8601.Qspi.write_command_opcode,
                .write_color_opcode = Sh8601.Qspi.write_color_opcode,
            },
        },
    });
    self.delay = .{};

    self.display = try Sh8601.display(.{
        .allocator = dma_allocator,
        .dbi = self.native_dbi.handle(),
        .delay = embed.drivers.Delay.init(&self.delay),
        .controller = panel_config,
        .flush = self.flushConfig(),
        .open = openController,
        .initial_brightness = panel_config.initial_brightness,
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
        .native_width = native_width_px,
        .native_height = native_height_px,
        .logical_width = width_px,
        .logical_height = height_px,
        .max_flush_rows = config.max_flush_rows,
        .rgb565_byte_order = .swapped,
        .orientation = .rotate_cw,
    };
}

fn openController(controller: *Sh8601) embed.drivers.Display.Error!void {
    controller.softwareReset() catch return error.DisplayError;
    controller.open() catch return error.DisplayError;
}

fn checkNative(rc: c_int) embed.drivers.Display.Error!void {
    if (rc == binding.esp_ok) return;
    return error.DisplayError;
}
