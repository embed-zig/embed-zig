const esp = @import("esp");
const hal_i2s = @import("hal").i2s;

pub const EndpointHandle = enum(u8) {
    rx = 1,
    tx = 2,
};

pub const Driver = struct {
    cfg: hal_i2s.BusConfig,
    rx: ?esp.esp_driver_i2s.I2sRx = null,
    tx: ?esp.esp_driver_i2s.I2sTx = null,
    rx_timeout_ms: u32 = 20,
    tx_timeout_ms: u32 = 20,

    pub fn initBus(cfg: hal_i2s.BusConfig) hal_i2s.Error!Driver {
        if (cfg.sample_rate_hz == 0) return error.InvalidParam;
        if (cfg.mode == .std and cfg.tdm_slot_mask != 0) return error.InvalidParam;
        if (cfg.mode == .tdm and cfg.tdm_slot_mask == 0) return error.InvalidParam;
        return .{ .cfg = cfg };
    }

    pub fn deinitBus(self: *Driver) void {
        if (self.rx) |rx| {
            rx.deinit() catch {};
            self.rx = null;
        }
        if (self.tx) |tx| {
            tx.deinit() catch {};
            self.tx = null;
        }
    }

    pub fn registerEndpoint(self: *Driver, ep: hal_i2s.EndpointConfig) hal_i2s.Error!EndpointHandle {
        return switch (ep.direction) {
            .rx => blk: {
                if (self.rx != null) return error.Busy;
                const rx = esp.esp_driver_i2s.I2sRx.init(.{
                    .port = self.cfg.port,
                    .role = mapRole(self.cfg.role),
                    .sample_rate_hz = self.cfg.sample_rate_hz,
                    .bits_per_sample = mapBits(self.cfg.bits_per_sample),
                    .rx_mode = mapMode(self.cfg.mode),
                    .slot_mode = mapSlot(self.cfg.slot_mode),
                    .tdm_slot_mask = self.cfg.tdm_slot_mask,
                    .mclk = self.cfg.mclk,
                    .bclk = self.cfg.bclk,
                    .ws = self.cfg.ws,
                    .din = ep.data_pin,
                    .dma_desc_num = self.cfg.dma_desc_num,
                    .dma_frame_num = self.cfg.dma_frame_num,
                }) catch |err| return mapEspError(err);
                self.rx = rx;
                self.rx_timeout_ms = ep.timeout_ms;
                break :blk .rx;
            },
            .tx => blk: {
                if (self.tx != null) return error.Busy;
                const tx = esp.esp_driver_i2s.I2sTx.init(.{
                    .port = self.cfg.port,
                    .role = mapRole(self.cfg.role),
                    .sample_rate_hz = self.cfg.sample_rate_hz,
                    .bits_per_sample = mapBits(self.cfg.bits_per_sample),
                    .tx_mode = mapTxMode(self.cfg.mode),
                    .slot_mode = mapSlot(self.cfg.slot_mode),
                    .tdm_slot_mask = self.cfg.tdm_slot_mask,
                    .mclk = self.cfg.mclk,
                    .bclk = self.cfg.bclk,
                    .ws = self.cfg.ws,
                    .dout = ep.data_pin,
                    .dma_desc_num = self.cfg.dma_desc_num,
                    .dma_frame_num = self.cfg.dma_frame_num,
                }) catch |err| return mapEspError(err);
                self.tx = tx;
                self.tx_timeout_ms = ep.timeout_ms;
                break :blk .tx;
            },
        };
    }

    pub fn unregisterEndpoint(self: *Driver, handle: EndpointHandle) hal_i2s.Error!void {
        switch (handle) {
            .rx => {
                if (self.rx) |rx| {
                    rx.deinit() catch {};
                    self.rx = null;
                } else return error.InvalidParam;
            },
            .tx => {
                if (self.tx) |tx| {
                    tx.deinit() catch {};
                    self.tx = null;
                } else return error.InvalidParam;
            },
        }
    }

    pub fn read(self: *Driver, handle: EndpointHandle, out: []u8) hal_i2s.Error!usize {
        if (handle != .rx) return error.InvalidDirection;
        const rx = self.rx orelse return error.InvalidParam;
        return rx.read(out, self.rx_timeout_ms) catch |err| return mapEspError(err);
    }

    pub fn write(self: *Driver, handle: EndpointHandle, input: []const u8) hal_i2s.Error!usize {
        if (handle != .tx) return error.InvalidDirection;
        const tx = self.tx orelse return error.InvalidParam;
        return tx.write(input, self.tx_timeout_ms) catch |err| return mapEspError(err);
    }
};

fn mapRole(role: hal_i2s.Role) esp.esp_driver_i2s.Role {
    return switch (role) {
        .master => .master,
        .slave => .slave,
    };
}

fn mapMode(mode: hal_i2s.Mode) esp.esp_driver_i2s.RxMode {
    return switch (mode) {
        .std => .std,
        .tdm => .tdm,
    };
}

fn mapTxMode(mode: hal_i2s.Mode) esp.esp_driver_i2s.TxMode {
    return switch (mode) {
        .std => .std,
        .tdm => .tdm,
    };
}

fn mapSlot(slot: hal_i2s.SlotMode) esp.esp_driver_i2s.SlotMode {
    return switch (slot) {
        .mono => .mono,
        .stereo => .stereo,
    };
}

fn mapBits(bits: hal_i2s.BitsPerSample) esp.esp_driver_i2s.BitsPerSample {
    return switch (bits) {
        .bits16 => .bits16,
        .bits24 => .bits24,
        .bits32 => .bits32,
    };
}

fn mapEspError(err: anyerror) hal_i2s.Error {
    return switch (err) {
        error.Timeout => error.Timeout,
        error.InvalidArg, error.InvalidState, error.InvalidSize => error.InvalidParam,
        error.NotSupported => error.InvalidParam,
        else => error.I2sError,
    };
}
