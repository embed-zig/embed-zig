const esp = @import("esp");
const hal_spi = @import("hal").spi;
const std = @import("std");

pub const Driver = struct {
    host_id: i32 = 2,
    mosi: i32 = -1,
    miso: i32 = -1,
    sclk: i32 = -1,
    timeout_ms: u32 = 1000,
    active_device: ?DeviceHandle = null,

    pub const DeviceHandle = struct {
        chip_select: i32,
        mode: u2 = 0,
        clock_hz: u32 = 1_000_000,
    };

    pub const Config = struct {
        host_id: i32 = 2,
        mosi: i32,
        miso: i32,
        sclk: i32,
        timeout_ms: u32 = 1000,
    };

    pub fn initMaster(cfg: Config) hal_spi.Error!Driver {
        return .{
            .host_id = cfg.host_id,
            .mosi = cfg.mosi,
            .miso = cfg.miso,
            .sclk = cfg.sclk,
            .timeout_ms = cfg.timeout_ms,
        };
    }

    pub fn deinit(self: *Driver) void {
        self.deinitActiveDevice();
    }

    pub fn registerDevice(_: *Driver, cfg: hal_spi.DeviceConfig) hal_spi.Error!DeviceHandle {
        return .{
            .chip_select = cfg.chip_select,
            .mode = cfg.mode,
            .clock_hz = cfg.clock_hz,
        };
    }

    pub fn unregisterDevice(self: *Driver, device: DeviceHandle) hal_spi.Error!void {
        if (self.active_device) |active| {
            if (deviceEqual(active, device)) {
                self.deinitActiveDevice();
            }
        }
    }

    pub fn write(self: *Driver, device: DeviceHandle, data: []const u8) hal_spi.Error!void {
        try self.ensureActiveDevice(device);
        esp.esp_driver_spi.masterWrite(self.host_id, data, self.timeout_ms) catch |err| return mapError(err);
    }

    pub fn transfer(self: *Driver, device: DeviceHandle, tx: []const u8, rx: []u8) hal_spi.Error!void {
        try self.ensureActiveDevice(device);
        esp.esp_driver_spi.masterTransfer(self.host_id, tx, rx, self.timeout_ms) catch |err| return mapError(err);
    }

    pub fn read(self: *Driver, device: DeviceHandle, buf: []u8) hal_spi.Error!void {
        try self.ensureActiveDevice(device);
        esp.esp_driver_spi.masterRead(self.host_id, buf, self.timeout_ms) catch |err| return mapError(err);
    }

    fn ensureActiveDevice(self: *Driver, device: DeviceHandle) hal_spi.Error!void {
        if (self.mosi < 0 or self.sclk < 0) return error.InvalidParam;
        if (self.active_device) |active| {
            if (deviceEqual(active, device)) return;
            self.deinitActiveDevice();
        }

        esp.esp_driver_spi.masterInit(
            self.host_id,
            self.mosi,
            self.miso,
            self.sclk,
            device.chip_select,
            device.clock_hz,
            device.mode,
        ) catch |err| return mapError(err);
        self.active_device = device;
    }

    fn deinitActiveDevice(self: *Driver) void {
        if (self.active_device != null) {
            esp.esp_driver_spi.masterDeinit(self.host_id) catch {};
            self.active_device = null;
        }
    }
};

fn deviceEqual(a: Driver.DeviceHandle, b: Driver.DeviceHandle) bool {
    return std.meta.eql(a, b);
}

fn mapError(err: anyerror) hal_spi.Error {
    return switch (err) {
        error.InvalidArg, error.InvalidArgument => error.InvalidParam,
        error.NotInitialized => error.Busy,
        error.InvalidState => error.Busy,
        error.Timeout => error.Timeout,
        else => error.TransferFailed,
    };
}
