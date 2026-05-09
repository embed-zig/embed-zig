const embed = @import("embed");
const esp = @import("esp");

const Pca9557 = embed.drivers.gpio.Pca9557;
const log = esp.grt.std.log.scoped(.szp_board_binding);

const i2c_port = 0;
const i2c_sda_gpio = 1;
const i2c_scl_gpio = 2;
const i2c_frequency_hz = 100_000;
const pca9557_address = 0x19;
const pca_lcd_cs_pin = Pca9557.Pin.pin0;
const pca_pa_en_pin = Pca9557.Pin.pin1;
const pca_dvp_pwdn_pin = Pca9557.Pin.pin2;
const pca_output_mask = pca_lcd_cs_pin.mask() | pca_pa_en_pin.mask() | pca_dvp_pwdn_pin.mask();
const pca_initial_output = pca_lcd_cs_pin.mask() | pca_dvp_pwdn_pin.mask();

pub const esp_ok: c_int = 0;
pub const esp_fail: c_int = -1;

var board_i2c_bus = esp.embed.I2c.MasterBus.init(.{
    .port = i2c_port,
    .sda_io_num = i2c_sda_gpio,
    .scl_io_num = i2c_scl_gpio,
    .scl_speed_hz = i2c_frequency_hz,
});
var pca9557: ?Pca9557 = null;

pub extern fn szp_board_init() c_int;

pub extern fn szp_storage_init_nvs() c_int;
pub extern fn szp_storage_mount() c_int;
pub extern fn szp_storage_info(total: *usize, used: *usize) c_int;
pub extern fn szp_storage_unmount() c_int;

pub extern fn szp_audio_init() c_int;
pub extern fn szp_audio_set_pa(enabled: bool) c_int;
pub extern fn szp_audio_write_i16(pcm: [*]const i16, sample_count: usize) c_int;
pub extern fn szp_audio_play_test_tone(frequency_hz: u32, duration_ms: u32) c_int;
pub extern fn szp_audio_mic_start() c_int;
pub extern fn szp_audio_mic_process_frame() c_int;
pub extern fn szp_audio_mic_stop() c_int;
pub extern fn szp_audio_mic_capture_start() c_int;
pub extern fn szp_audio_mic_read_i16(mic0: [*]i16, mic1: [*]i16, ref: [*]i16, sample_capacity: usize, sample_count: *usize) c_int;
pub extern fn szp_audio_mic_capture_stop() c_int;
pub extern fn szp_audio_afe_process_i16(
    mic0: [*]const i16,
    mic1: [*]const i16,
    ref: [*]const i16,
    sample_count: usize,
    out: [*]i16,
    out_capacity: usize,
    out_count: *usize,
) c_int;

pub extern fn szp_button_init() c_int;
pub extern fn szp_button_read_raw() bool;

pub extern fn szp_display_native_init() c_int;
pub extern fn szp_display_native_draw_rgb565(
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: [*]const u16,
    len: usize,
) c_int;

pub fn i2cDevice(address: embed.drivers.I2c.Address) !embed.drivers.I2c {
    try board_i2c_bus.open();
    return board_i2c_bus.device(address);
}

pub export fn szp_i2c_init() c_int {
    board_i2c_bus.open() catch |err| return boardI2cError("szp_i2c_init", err);
    return esp_ok;
}

pub export fn szp_i2c_write_reg(address: u8, reg: u8, value: u8) c_int {
    const i2c_address = checkedI2cAddress(address) catch |err| return boardI2cError("szp_i2c_write_reg", err);
    const i2c = board_i2c_bus.device(i2c_address) catch |err| return boardI2cError("szp_i2c_write_reg", err);
    i2c.write(i2c_address, &.{ reg, value }) catch |err| return boardI2cError("szp_i2c_write_reg", err);
    return esp_ok;
}

pub export fn szp_i2c_read_reg(address: u8, reg: u8, value: ?*u8) c_int {
    const out = value orelse return esp_fail;
    const i2c_address = checkedI2cAddress(address) catch |err| return boardI2cError("szp_i2c_read_reg", err);
    const i2c = board_i2c_bus.device(i2c_address) catch |err| return boardI2cError("szp_i2c_read_reg", err);

    var rx: [1]u8 = undefined;
    i2c.writeRead(i2c_address, &.{reg}, &rx) catch |err| return boardI2cError("szp_i2c_read_reg", err);
    out.* = rx[0];
    return esp_ok;
}

pub export fn szp_pca9557_init() c_int {
    initPca9557() catch |err| return boardI2cError("szp_pca9557_init", err);
    return esp_ok;
}

pub export fn szp_pca9557_set_lcd_cs(high: bool) c_int {
    setPca9557Pin(pca_lcd_cs_pin, high) catch |err| return boardI2cError("szp_pca9557_set_lcd_cs", err);
    return esp_ok;
}

pub export fn szp_pca9557_set_pa(enabled: bool) c_int {
    setPca9557Pin(pca_pa_en_pin, enabled) catch |err| return boardI2cError("szp_pca9557_set_pa", err);
    return esp_ok;
}

fn checkedI2cAddress(address: u8) !embed.drivers.I2c.Address {
    if (address > 0x7f) return error.InvalidI2cAddress;
    return @intCast(address);
}

fn initPca9557() !void {
    try board_i2c_bus.open();
    const i2c = try board_i2c_bus.device(pca9557_address);
    var driver = Pca9557.init(i2c, pca9557_address);
    try driver.configureMultiple(pca_output_mask, pca_initial_output);
    pca9557 = driver;
}

fn setPca9557Pin(pin: Pca9557.Pin, high: bool) !void {
    const driver = try ensurePca9557();
    try driver.write(pin, if (high) .high else .low);
}

fn ensurePca9557() !*Pca9557 {
    if (pca9557 == null) {
        try initPca9557();
    }
    if (pca9557) |*driver| return driver;
    return error.BoardCallFailed;
}

fn boardI2cError(name: []const u8, err: anyerror) c_int {
    log.err("{s} failed: {s}", .{ name, @errorName(err) });
    return esp_fail;
}
