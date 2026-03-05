const esp = @import("esp");
const hal_i2c = @import("hal").i2c;

pub const Driver = struct {
    port: i32 = 0,
    timeout_ms: u32 = 1000,

    pub const DeviceHandle = struct {
        address: u7,
        timeout_ms: u32,
    };

    pub const Config = struct {
        port: u8 = 0,
        sda: u8,
        scl: u8,
        freq_hz: u32 = 400_000,
        timeout_ms: u32 = 1000,
    };

    pub fn initMaster(cfg: Config) hal_i2c.Error!Driver {
        esp.esp_driver_i2c.masterInit(@intCast(cfg.port), @intCast(cfg.sda), @intCast(cfg.scl), cfg.freq_hz) catch |err| return mapError(err);
        return .{
            .port = @intCast(cfg.port),
            .timeout_ms = cfg.timeout_ms,
        };
    }

    pub fn registerDevice(self: *Driver, cfg: hal_i2c.DeviceConfig) hal_i2c.Error!DeviceHandle {
        _ = self;
        return .{
            .address = cfg.address,
            .timeout_ms = cfg.timeout_ms,
        };
    }

    pub fn unregisterDevice(_: *Driver, _: DeviceHandle) hal_i2c.Error!void {}

    pub fn write(self: *Driver, device: DeviceHandle, data: []const u8) hal_i2c.Error!void {
        const timeout_ms = if (device.timeout_ms == 0) self.timeout_ms else device.timeout_ms;
        esp.esp_driver_i2c.masterWrite(self.port, device.address, data, timeout_ms) catch |err| return mapError(err);
    }

    pub fn writeRead(self: *Driver, device: DeviceHandle, write_data: []const u8, read_buf: []u8) hal_i2c.Error!void {
        const timeout_ms = if (device.timeout_ms == 0) self.timeout_ms else device.timeout_ms;
        esp.esp_driver_i2c.masterWriteRead(self.port, device.address, write_data, read_buf, timeout_ms) catch |err| return mapError(err);
    }
};

fn mapError(err: anyerror) hal_i2c.Error {
    return switch (err) {
        error.InvalidArgument => error.InvalidParam,
        else => error.I2cError,
    };
}
