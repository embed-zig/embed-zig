const embed = @import("embed_core");
const esp = @import("esp");
const I2c = @import("../../../embed/I2c.zig");

const Tca9554 = embed.drivers.gpio.Tca9554;
const log = esp.grt.std.log.scoped(.wv_board_binding);

const i2c_port = 0;
const i2c_sda_gpio = 15;
const i2c_scl_gpio = 14;
const i2c_frequency_hz = 200_000;
const tca9554_address = Tca9554.Address.TCA9554_BASE;
const power_mask = Tca9554.Pin.pin0.mask() | Tca9554.Pin.pin1.mask() | Tca9554.Pin.pin2.mask();

pub const esp_ok: c_int = 0;
pub const esp_fail: c_int = -1;

var board_i2c_bus = I2c.MasterBus.init(.{
    .port = i2c_port,
    .sda_io_num = i2c_sda_gpio,
    .scl_io_num = i2c_scl_gpio,
    .scl_speed_hz = i2c_frequency_hz,
});
var expander: ?Tca9554 = null;
var board_initialized = false;

pub extern fn wv_power_button_init() c_int;
pub extern fn wv_power_button_pressed() bool;

pub extern fn wv_storage_init_nvs() c_int;

pub extern fn wv_display_native_init() c_int;
pub extern fn wv_display_native_panel_io() ?*anyopaque;

pub extern fn wv_audio_set_pa(enabled: bool) c_int;

pub fn boardInit() !void {
    if (board_initialized) return;
    board_i2c_bus.open() catch |err| {
        log.err("board init: open i2c bus failed: {s}", .{@errorName(err)});
        return err;
    };
    initExpander() catch |err| {
        log.err("board init: init expander failed: {s}", .{@errorName(err)});
        return err;
    };
    powerOnPeripherals() catch |err| {
        log.err("board init: power on peripherals failed: {s}", .{@errorName(err)});
        return err;
    };
    board_initialized = true;
}

pub fn i2cDevice(address: embed.drivers.I2c.Address) !embed.drivers.I2c {
    try board_i2c_bus.open();
    return board_i2c_bus.device(address);
}

fn initExpander() !void {
    if (expander != null) return;

    const i2c = try board_i2c_bus.device(tca9554_address);
    var driver = Tca9554.init(i2c, tca9554_address);
    driver.writeMask(power_mask, 0) catch |err| {
        log.err("board init: write tca9554 output failed: {s}", .{@errorName(err)});
        return err;
    };
    driver.setDirectionMask(power_mask) catch |err| {
        log.err("board init: set tca9554 direction failed: {s}", .{@errorName(err)});
        return err;
    };
    expander = driver;
}

fn powerOnPeripherals() !void {
    const driver = try ensureExpander();
    try driver.writeMask(power_mask, 0);
    esp.grt.std.Thread.sleep(200 * esp.grt.time.duration.MilliSecond);
    try driver.writeMask(power_mask, power_mask);
}

fn ensureExpander() !*Tca9554 {
    if (expander == null) {
        try initExpander();
    }
    if (expander) |*driver| return driver;
    return error.BoardCallFailed;
}

pub fn logError(name: []const u8, err: anyerror) void {
    log.err("{s} failed: {s}", .{ name, @errorName(err) });
}
