const embed = @import("embed_core");
const I2c = @import("../../../embed/I2c.zig");

const i2c_port = 0;
const i2c_sda_gpio = 7;
const i2c_scl_gpio = 8;
const i2c_frequency_hz = 200_000;

pub const esp_ok: c_int = 0;
pub const esp_fail: c_int = -1;

var board_i2c_bus = I2c.MasterBus.init(.{
    .port = i2c_port,
    .sda_io_num = i2c_sda_gpio,
    .scl_io_num = i2c_scl_gpio,
    .scl_speed_hz = i2c_frequency_hz,
});

pub extern fn wv_p4_board_init() c_int;
pub extern fn wv_p4_power_button_init() c_int;
pub extern fn wv_p4_power_button_pressed() bool;

pub extern fn wv_p4_display_native_init() c_int;
pub extern fn wv_p4_display_native_panel_io() ?*anyopaque;
pub extern fn wv_p4_display_native_reset_panel() c_int;
pub extern fn wv_p4_display_native_start_panel() c_int;
pub extern fn wv_p4_display_native_set_brightness(brightness: u8) c_int;
pub extern fn wv_p4_display_native_flush_rgb565(
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: [*]const u16,
    len: usize,
) c_int;

pub extern fn wv_p4_audio_set_pa(enabled: bool) c_int;

pub fn i2cDevice(address: embed.drivers.I2c.Address) !embed.drivers.I2c {
    try board_i2c_bus.open();
    return board_i2c_bus.device(address);
}
