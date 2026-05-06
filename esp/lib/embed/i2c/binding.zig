const embed = @import("embed");

pub const Handle = ?*anyopaque;
pub const default_timeout_ms: i32 = 1000;

pub extern const espz_embed_i2c_esp_ok: i32;
pub extern const espz_embed_i2c_esp_err_timeout: i32;
pub extern const espz_embed_i2c_esp_err_invalid_arg: i32;
pub extern const espz_embed_i2c_esp_err_invalid_state: i32;

pub extern fn espz_embed_i2c_new_master_bus(
    port: i32,
    sda_io_num: i32,
    scl_io_num: i32,
    glitch_ignore_cnt: u32,
    enable_internal_pullup: bool,
    out_bus: *Handle,
) i32;

pub extern fn espz_embed_i2c_del_master_bus(bus: Handle) i32;

pub extern fn espz_embed_i2c_master_get_bus_handle(
    port: i32,
    out_bus: *Handle,
) i32;

pub extern fn espz_embed_i2c_master_bus_add_device(
    bus: Handle,
    address: u8,
    scl_speed_hz: u32,
    out_device: *Handle,
) i32;

pub extern fn espz_embed_i2c_master_bus_rm_device(device: Handle) i32;

pub extern fn espz_embed_i2c_master_transmit(
    device: Handle,
    data: [*]const u8,
    len: usize,
    timeout_ms: i32,
) i32;

pub extern fn espz_embed_i2c_master_receive(
    device: Handle,
    data: [*]u8,
    len: usize,
    timeout_ms: i32,
) i32;

pub extern fn espz_embed_i2c_master_transmit_receive(
    device: Handle,
    tx: [*]const u8,
    tx_len: usize,
    rx: [*]u8,
    rx_len: usize,
    timeout_ms: i32,
) i32;

pub fn isInvalidState(rc: i32) bool {
    return rc == espz_embed_i2c_esp_err_invalid_state;
}

pub fn check(rc: i32) embed.drivers.I2c.Error!void {
    if (rc == espz_embed_i2c_esp_ok) return;
    if (rc == espz_embed_i2c_esp_err_timeout) return error.Timeout;
    if (rc == espz_embed_i2c_esp_err_invalid_state) return error.BusError;
    if (rc == espz_embed_i2c_esp_err_invalid_arg) return error.BusError;
    return error.Unexpected;
}
