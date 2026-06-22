const bk = @import("../../bk.zig");
const embed = @import("embed_core");
const glib = @import("glib");
const binding = @import("binding.zig");

const Qspi = @This();
const Display = embed.drivers.Display;
const Flush = Display.Flush;
const St77903 = Display.St77903;

pub const Config = struct {
    allocator: glib.std.mem.Allocator,
    qspi_id: u8 = 0,
    reset_pin: u8 = 40,
    backlight_pin: u8 = 7,
    max_flush_rows: u16 = 0,
    rgb565_byte_order: Flush.Rgb565ByteOrder = St77903.defaultH0165Y008TFlushConfig(1).rgb565_byte_order,
};

config: Flush.Config = undefined,
allocator: glib.std.mem.Allocator = undefined,
scratch: []u16 = &.{},
brightness_level: u8 = 0,

pub fn init(config: Config) !Qspi {
    try check(binding.bk_embed_display_qspi_init(config.qspi_id, config.reset_pin, config.backlight_pin));

    const width_px = binding.bk_embed_display_qspi_width();
    const height_px = binding.bk_embed_display_qspi_height();
    if (width_px == 0 or height_px == 0) return error.DisplayError;

    const max_flush_rows = if (config.max_flush_rows == 0) height_px else config.max_flush_rows;
    var flush_config = St77903.defaultH0165Y008TFlushConfig(max_flush_rows);
    flush_config.native_width = width_px;
    flush_config.native_height = height_px;
    flush_config.logical_width = width_px;
    flush_config.logical_height = height_px;
    flush_config.rgb565_byte_order = config.rgb565_byte_order;

    const scratch = try config.allocator.alloc(u16, Flush.maxChunkPixels(flush_config));
    errdefer config.allocator.free(scratch);

    return .{
        .config = flush_config,
        .allocator = config.allocator,
        .scratch = scratch,
    };
}

pub fn display(config: Config) !Display {
    return Display.make(bk.ap.grt, Qspi).init(config);
}

pub fn deinit(self: *Qspi) void {
    if (self.scratch.len != 0) {
        self.allocator.free(self.scratch);
        self.scratch = &.{};
    }
    binding.bk_embed_display_qspi_deinit();
}

pub fn width(self: *Qspi) u16 {
    return Flush.width(self.config);
}

pub fn height(self: *Qspi) u16 {
    return Flush.height(self.config);
}

pub fn maxFlushPixels(self: *Qspi) !usize {
    return Flush.maxChunkPixels(self.config);
}

pub fn setEnabled(_: *Qspi, is_enabled: bool) !void {
    try check(binding.bk_embed_display_qspi_set_enabled(is_enabled));
}

pub fn enabled(_: *Qspi) !bool {
    return binding.bk_embed_display_qspi_enabled();
}

pub fn setBrightness(self: *Qspi, level: u8) !void {
    try check(binding.bk_embed_display_qspi_set_brightness(level));
    self.brightness_level = level;
}

pub fn brightness(self: *Qspi) !u8 {
    _ = self;
    return binding.bk_embed_display_qspi_brightness();
}

pub fn flush(self: *Qspi, x: u16, y: u16, w: u16, h: u16, pixels: []const Display.Rgb) !void {
    try Flush.validate(self.config, x, y, w, h, pixels);
    const encoded = try Flush.encodeChunk(self.config, self.scratch, pixels, 0, w, h);
    const area = Flush.nativeArea(self.config, x, y, w, 0, h);
    try check(binding.bk_embed_display_qspi_flush_rgb565(
        area.x,
        area.y,
        area.w,
        area.h,
        encoded.ptr,
        encoded.len,
    ));
}

fn check(rc: c_int) Display.Error!void {
    return switch (rc) {
        binding.ok => {},
        binding.invalid_arg => error.OutOfBounds,
        binding.invalid_state => error.Busy,
        else => error.DisplayError,
    };
}
