pub const ok: c_int = 0;
pub const invalid_arg: c_int = 1;
pub const invalid_state: c_int = 2;
pub const no_mem: c_int = 3;
pub const unexpected: c_int = 9;

pub extern fn bk_embed_display_qspi_init(qspi_id: u8, reset_pin: u8, backlight_pin: u8) c_int;
pub extern fn bk_embed_display_qspi_deinit() void;
pub extern fn bk_embed_display_qspi_width() u16;
pub extern fn bk_embed_display_qspi_height() u16;
pub extern fn bk_embed_display_qspi_set_enabled(enabled: bool) c_int;
pub extern fn bk_embed_display_qspi_enabled() bool;
pub extern fn bk_embed_display_qspi_set_brightness(level: u8) c_int;
pub extern fn bk_embed_display_qspi_brightness() u8;
pub extern fn bk_embed_display_qspi_flush_rgb565(
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: [*]const u16,
    len: usize,
) c_int;

pub extern fn bk_embed_display_rgb_init(clk_pin: u8, cs_pin: u8, sda_pin: u8, reset_pin: u8, ldo_pin: u8, backlight_pin: u8) c_int;
pub extern fn bk_embed_display_rgb_deinit() void;
pub extern fn bk_embed_display_rgb_width() u16;
pub extern fn bk_embed_display_rgb_height() u16;
pub extern fn bk_embed_display_rgb_set_enabled(enabled: bool) c_int;
pub extern fn bk_embed_display_rgb_enabled() bool;
pub extern fn bk_embed_display_rgb_set_brightness(level: u8) c_int;
pub extern fn bk_embed_display_rgb_brightness() u8;
pub extern fn bk_embed_display_rgb_flush_rgb565(
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: [*]const u16,
    len: usize,
) c_int;
pub extern fn bk_embed_display_rgb_debug_colorbar() c_int;
pub extern fn bk_embed_display_rgb_debug_official_colorbar() c_int;
