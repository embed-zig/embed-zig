const bk = @import("../../bk.zig");
const embed = @import("embed_core");
const glib = @import("glib");
const binding = @import("binding.zig");

const Rgb = @This();
const Display = embed.drivers.Display;
const Flush = Display.Flush;

pub const Config = struct {
    allocator: glib.std.mem.Allocator,
    clk_pin: u8 = 0,
    cs_pin: u8 = 12,
    sda_pin: u8 = 1,
    reset_pin: u8 = 6,
    ldo_pin: u8 = 13,
    backlight_pin: u8 = 7,
    max_flush_rows: u16 = 0,
    rgb565_byte_order: Flush.Rgb565ByteOrder = .native,
};

config: Flush.Config = undefined,
allocator: glib.std.mem.Allocator = undefined,
scratch: []u16 = &.{},
brightness_level: u8 = 0,

pub fn init(config: Config) !Rgb {
    try check(binding.bk_embed_display_rgb_init(
        config.clk_pin,
        config.cs_pin,
        config.sda_pin,
        config.reset_pin,
        config.ldo_pin,
        config.backlight_pin,
    ));

    const width_px = binding.bk_embed_display_rgb_width();
    const height_px = binding.bk_embed_display_rgb_height();
    if (width_px == 0 or height_px == 0) return error.DisplayError;

    const max_flush_rows = if (config.max_flush_rows == 0) height_px else config.max_flush_rows;
    const flush_config = Flush.Config{
        .native_width = width_px,
        .native_height = height_px,
        .logical_width = width_px,
        .logical_height = height_px,
        .max_flush_rows = max_flush_rows,
        .rgb565_byte_order = config.rgb565_byte_order,
    };

    const scratch = try config.allocator.alloc(u16, Flush.maxChunkPixels(flush_config));
    errdefer config.allocator.free(scratch);

    return .{
        .config = flush_config,
        .allocator = config.allocator,
        .scratch = scratch,
    };
}

pub fn display(config: Config) !Display {
    return Display.make(bk.ap.grt, Rgb).init(config);
}

pub fn deinit(self: *Rgb) void {
    if (self.scratch.len != 0) {
        self.allocator.free(self.scratch);
        self.scratch = &.{};
    }
    binding.bk_embed_display_rgb_deinit();
}

pub fn width(self: *Rgb) u16 {
    return Flush.width(self.config);
}

pub fn height(self: *Rgb) u16 {
    return Flush.height(self.config);
}

pub fn maxFlushPixels(self: *Rgb) !usize {
    return Flush.maxChunkPixels(self.config);
}

pub fn setEnabled(_: *Rgb, is_enabled: bool) !void {
    try check(binding.bk_embed_display_rgb_set_enabled(is_enabled));
}

pub fn enabled(_: *Rgb) !bool {
    return binding.bk_embed_display_rgb_enabled();
}

pub fn setBrightness(self: *Rgb, level: u8) !void {
    try check(binding.bk_embed_display_rgb_set_brightness(level));
    self.brightness_level = level;
}

pub fn brightness(self: *Rgb) !u8 {
    _ = self;
    return binding.bk_embed_display_rgb_brightness();
}

pub fn flush(self: *Rgb, x: u16, y: u16, w: u16, h: u16, pixels: []const Display.Rgb) !void {
    try Flush.validate(self.config, x, y, w, h, pixels);
    const encoded = try Flush.encodeChunk(self.config, self.scratch, pixels, 0, w, h);
    const area = Flush.nativeArea(self.config, x, y, w, 0, h);
    try check(binding.bk_embed_display_rgb_flush_rgb565(
        area.x,
        area.y,
        area.w,
        area.h,
        encoded.ptr,
        encoded.len,
    ));
}

pub fn debugColorbar() !void {
    try check(binding.bk_embed_display_rgb_debug_colorbar());
}

pub fn debugOfficialColorbar() !void {
    try check(binding.bk_embed_display_rgb_debug_official_colorbar());
}

fn check(rc: c_int) Display.Error!void {
    return switch (rc) {
        binding.ok => {},
        binding.invalid_arg => error.OutOfBounds,
        binding.invalid_state => error.Busy,
        else => error.DisplayError,
    };
}
