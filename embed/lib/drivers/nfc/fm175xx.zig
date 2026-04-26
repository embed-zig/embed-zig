//! Fm175xx — FM175xx-family NFC reader driver.
//!
//! Local design notes: `lib/drivers/nfc/AGENTS.md`
//! Local driver notes: `lib/drivers/nfc/fm175xx.md`

const glib = @import("glib");
const Delay = @import("../Delay.zig");
const I2c = @import("../I2c.zig");
const Spi = @import("../Spi.zig");
const TypeA = @import("io/TypeA.zig");
const regs = @import("fm175xx/regs.zig");
const type_a = @import("fm175xx/type_a.zig");
const ntag = @import("fm175xx/ntag.zig");

const Fm175xx = @This();

pub const Error = error{
    Timeout,
    Nack,
    BusError,
    ArbitrationLost,
    InvalidState,
    InvalidArgument,
    Protocol,
    Unexpected,
    UnsupportedOperation,
};

pub const IsoType = enum {
    a,
    b,
};

pub const RfPath = enum(u2) {
    off = 0,
    path1 = 1,
    path2 = 2,
    both = 3,
};

pub const TypeACard = type_a.Card;

pub const I2cConfig = struct {
    address: I2c.Address = 0x28,
    power: ?Power = null,
};

pub const SpiConfig = struct {
    power: ?Power = null,
};

pub const Power = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        enable: *const fn (ptr: *anyopaque) void,
        disable: *const fn (ptr: *anyopaque) void,
    };

    pub fn init(pointer: anytype) Power {
        const Ptr = @TypeOf(pointer);
        const info = @typeInfo(Ptr);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("Fm175xx.Power.init expects a single-item pointer");

        const Impl = info.pointer.child;

        const gen = struct {
            fn enableFn(ptr: *anyopaque) void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                self.enable();
            }

            fn disableFn(ptr: *anyopaque) void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                self.disable();
            }

            const vtable = VTable{
                .enable = enableFn,
                .disable = disableFn,
            };
        };

        return .{
            .ptr = pointer,
            .vtable = &gen.vtable,
        };
    }

    pub fn enable(self: Power) void {
        self.vtable.enable(self.ptr);
    }

    pub fn disable(self: Power) void {
        self.vtable.disable(self.ptr);
    }
};

delay: Delay,
power: ?Power,
backend: Backend,

pub fn initI2c(bus: I2c, delay: Delay, config: I2cConfig) Fm175xx {
    return .{
        .delay = delay,
        .power = config.power,
        .backend = .{
            .i2c = .{
                .bus = bus,
                .address = config.address,
            },
        },
    };
}

pub fn initSpi(bus: Spi, delay: Delay, config: SpiConfig) Fm175xx {
    return .{
        .delay = delay,
        .power = config.power,
        .backend = .{
            .spi = .{
                .bus = bus,
            },
        },
    };
}

pub fn open(self: *Fm175xx) Error!void {
    self.enable();
    self.delay.sleepMs(100);
}

pub fn close(self: *Fm175xx) void {
    self.disable();
}

pub fn enable(self: *Fm175xx) void {
    if (self.power) |power| power.enable();
}

pub fn disable(self: *Fm175xx) void {
    if (self.power) |power| power.disable();
}

pub fn hardReset(self: *Fm175xx) Error!void {
    self.disable();
    self.delay.sleepMs(1);
    self.enable();
    self.delay.sleepMs(1);
}

pub fn softReset(self: *Fm175xx) Error!void {
    try self.writeByte(regs.command, regs.cmd_soft_reset);
    self.delay.sleepMs(1);
    _ = try self.setBitMask(regs.control, 0x10);
}

pub fn setIsoType(self: *Fm175xx, iso_type: IsoType) Error!void {
    switch (iso_type) {
        .a => {
            _ = try self.setBitMask(regs.control, 0x10);
            _ = try self.setBitMask(regs.tx_auto, 0x40);
            try self.writeByte(regs.tx_mode, 0x00);
            try self.writeByte(regs.rx_mode, 0x00);
            try self.writeByte(regs.gsn, 0xF8);
            try self.writeByte(regs.gwgsp, 0x3F);
            try self.writeByte(regs.rfcfg, 0x68);
            try self.writeByte(regs.rx_thres, 0x74);
        },
        .b => return error.UnsupportedOperation,
    }
}

pub fn setRf(self: *Fm175xx, path: RfPath) Error!void {
    var expected = try self.readByte(regs.tx_ctrl);
    if (expected == 0xFF) return error.InvalidState;
    if ((expected & 0x03) == @intFromEnum(path)) return;

    switch (path) {
        .off => {
            expected = 0x80;
            _ = try self.clearBitMask(regs.tx_ctrl, 0x03);
        },
        .path1 => {
            expected = 0x81;
            try self.writeByte(regs.tx_ctrl, expected);
        },
        .path2 => {
            expected = 0x82;
            try self.writeByte(regs.tx_ctrl, expected);
        },
        .both => {
            expected = 0x83;
            _ = try self.setBitMask(regs.tx_ctrl, 0x03);
        },
    }

    self.delay.sleepMs(5);
    const observed = try self.readByte(regs.tx_ctrl);
    if (observed != expected) return error.InvalidState;
}

pub fn typeA(self: *Fm175xx) TypeA {
    return TypeA.init(self);
}

pub fn activateTypeA(self: *Fm175xx) Error!TypeACard {
    try self.setIsoType(.a);
    return try type_a.activate(self.typeA());
}

pub fn ntagRead(self: *Fm175xx, addr: u8, out: []u8) Error!void {
    try self.setIsoType(.a);
    return try ntag.read(self.typeA(), addr, out);
}

pub fn ntagReadAll(self: *Fm175xx, out: []u8) Error!usize {
    try self.setIsoType(.a);
    return try ntag.readAll(self.typeA(), out);
}

pub fn transceive(self: *Fm175xx, exchange: TypeA.Exchange, rx: []u8) TypeA.Error!usize {
    if (exchange.tx.len == 0) return error.InvalidArgument;
    if (exchange.tx_bits == 0) return error.InvalidArgument;
    if (exchange.timeout_ms == 0) return error.InvalidArgument;
    if (exchange.timeout_ms > TypeA.max_timeout_ms) return error.InvalidArgument;
    if (exchange.tx_bits > exchange.tx.len * 8) return error.InvalidArgument;

    try self.preCommand();
    try self.prepareExchange(exchange);
    _ = try self.setBitMask(regs.tmode, 0x80);
    try self.writeByte(regs.command, regs.cmd_transceive);

    var tx_index: usize = 0;
    var out_len: usize = 0;
    var pending_error: ?TypeA.Error = null;
    var completed = false;
    var poll_budget: u32 = exchange.timeout_ms + 8;

    while (poll_budget > 0) : (poll_budget -= 1) {
        const irq = try self.readByte(regs.com_irq);
        if ((irq & 0x01) != 0) {
            pending_error = error.Timeout;
            completed = true;
            break;
        }

        if (((irq & 0x04) != 0) and (tx_index < exchange.tx.len)) {
            const remaining = exchange.tx.len - tx_index;
            const chunk_len: usize = if (remaining > 32) 32 else remaining;
            try self.writeFifo(exchange.tx[tx_index .. tx_index + chunk_len]);
            tx_index += chunk_len;

            const framing = try self.readByte(regs.bit_framing);
            try self.writeByte(regs.bit_framing, framing | regs.start_send);
            try self.writeByte(regs.com_irq, 0x04);
        }

        if (((irq & 0x08) != 0) and ((irq & 0x40) != 0) and (tx_index == exchange.tx.len)) {
            const fifo_len = try self.readByte(regs.fifo_level);
            if (fifo_len > 32) {
                if (out_len + 32 > rx.len) {
                    pending_error = error.InvalidArgument;
                    completed = true;
                    break;
                }
                try self.readFifo(rx[out_len .. out_len + 32]);
                out_len += 32;
                try self.writeByte(regs.com_irq, 0x08);
            }
        }

        if (((irq & 0x20) != 0) and (tx_index == exchange.tx.len)) {
            completed = true;
            break;
        }
        self.delay.sleepMs(1);
    }

    if (!completed and pending_error == null) pending_error = error.Timeout;

    var last_fifo_len = try self.readByte(regs.fifo_level);
    const last_bits = (try self.readByte(regs.control)) & 0x07;
    if ((last_fifo_len == 0) and (last_bits > 0)) last_fifo_len = 1;

    if (pending_error == null) {
        if (out_len + last_fifo_len > rx.len) {
            pending_error = error.InvalidArgument;
        } else {
            try self.readFifo(rx[out_len .. out_len + last_fifo_len]);
            out_len += last_fifo_len;
        }
    }

    const out_bits: usize = if (last_bits > 0)
        (out_len - 1) * 8 + last_bits
    else
        out_len * 8;

    return self.finishCommand(pending_error, out_bits);
}

const Backend = union(enum) {
    i2c: I2cBackend,
    spi: SpiBackend,

    fn writeByte(self: *Backend, addr: u8, value: u8) TypeA.Error!void {
        return switch (self.*) {
            .i2c => |*backend| backend.writeByte(addr, value),
            .spi => |*backend| backend.writeByte(addr, value),
        };
    }

    fn readByte(self: *Backend, addr: u8) TypeA.Error!u8 {
        return switch (self.*) {
            .i2c => |*backend| backend.readByte(addr),
            .spi => |*backend| backend.readByte(addr),
        };
    }

    fn write(self: *Backend, addr: u8, data: []const u8) TypeA.Error!void {
        return switch (self.*) {
            .i2c => |*backend| backend.write(addr, data),
            .spi => |*backend| backend.write(addr, data),
        };
    }

    fn read(self: *Backend, addr: u8, buf: []u8) TypeA.Error!void {
        return switch (self.*) {
            .i2c => |*backend| backend.read(addr, buf),
            .spi => |*backend| backend.read(addr, buf),
        };
    }
};

const I2cBackend = struct {
    bus: I2c,
    address: I2c.Address,

    fn writeByte(self: *const I2cBackend, addr: u8, value: u8) TypeA.Error!void {
        return self.bus.write(self.address, &.{ addr, value });
    }

    fn readByte(self: *const I2cBackend, addr: u8) TypeA.Error!u8 {
        var value: [1]u8 = undefined;
        try self.bus.writeRead(self.address, &.{addr}, &value);
        return value[0];
    }

    fn write(self: *const I2cBackend, addr: u8, data: []const u8) TypeA.Error!void {
        if (data.len == 0) return error.InvalidArgument;
        if (data.len + 1 > 65) return error.InvalidArgument;

        var tx: [65]u8 = undefined;
        tx[0] = addr;
        @memcpy(tx[1 .. data.len + 1], data);
        return self.bus.write(self.address, tx[0 .. data.len + 1]);
    }

    fn read(self: *const I2cBackend, addr: u8, buf: []u8) TypeA.Error!void {
        if (buf.len == 0) return;
        return self.bus.writeRead(self.address, &.{addr}, buf);
    }
};

const SpiBackend = struct {
    bus: Spi,

    fn writeByte(self: *const SpiBackend, addr: u8, value: u8) TypeA.Error!void {
        var rx: [2]u8 = undefined;
        const tx = [_]u8{ (addr << 1) & 0x7E, value };
        try self.bus.transfer(&tx, &rx);
    }

    fn readByte(self: *const SpiBackend, addr: u8) TypeA.Error!u8 {
        var rx: [2]u8 = undefined;
        const tx = [_]u8{ (addr << 1) | 0x80, 0x00 };
        try self.bus.transfer(&tx, &rx);
        return rx[1];
    }

    fn write(self: *const SpiBackend, addr: u8, data: []const u8) TypeA.Error!void {
        if (data.len == 0) return error.InvalidArgument;
        if (data.len + 1 > 65) return error.InvalidArgument;

        var tx: [65]u8 = undefined;
        var rx: [65]u8 = undefined;
        tx[0] = (addr << 1) & 0x7E;
        @memcpy(tx[1 .. data.len + 1], data);
        try self.bus.transfer(tx[0 .. data.len + 1], rx[0 .. data.len + 1]);
    }

    fn read(self: *const SpiBackend, addr: u8, buf: []u8) TypeA.Error!void {
        if (buf.len == 0) return;
        if (buf.len + 1 > 65) return error.InvalidArgument;

        var tx: [65]u8 = undefined;
        var rx: [65]u8 = undefined;

        tx[0] = (addr << 1) | 0x80;
        if (buf.len > 1) {
            var i: usize = 0;
            while (i < buf.len - 1) : (i += 1) tx[i + 1] = (addr << 1) | 0x80;
        }
        tx[buf.len] = 0x00;

        try self.bus.transfer(tx[0 .. buf.len + 1], rx[0 .. buf.len + 1]);
        @memcpy(buf, rx[1 .. buf.len + 1]);
    }
};

fn writeByte(self: *Fm175xx, addr: u8, value: u8) TypeA.Error!void {
    return self.backend.writeByte(addr, value);
}

fn readByte(self: *Fm175xx, addr: u8) TypeA.Error!u8 {
    return self.backend.readByte(addr);
}

fn write(self: *Fm175xx, addr: u8, data: []const u8) TypeA.Error!void {
    return self.backend.write(addr, data);
}

fn read(self: *Fm175xx, addr: u8, buf: []u8) TypeA.Error!void {
    return self.backend.read(addr, buf);
}

fn writeFifo(self: *Fm175xx, data: []const u8) TypeA.Error!void {
    return self.write(regs.fifo_data, data);
}

fn readFifo(self: *Fm175xx, buf: []u8) TypeA.Error!void {
    return self.read(regs.fifo_data, buf);
}

fn clearFifo(self: *Fm175xx) TypeA.Error!void {
    _ = try self.setBitMask(regs.fifo_level, 0x80);
    if ((try self.readByte(regs.fifo_level)) != 0) return error.InvalidState;
}

fn setBitMask(self: *Fm175xx, addr: u8, bits: u8) TypeA.Error!u8 {
    const value = (try self.readByte(addr)) | bits;
    try self.writeByte(addr, value);
    return value;
}

fn clearBitMask(self: *Fm175xx, addr: u8, bits: u8) TypeA.Error!u8 {
    const value = (try self.readByte(addr)) & ~bits;
    try self.writeByte(addr, value);
    return value;
}

fn setTimer(self: *Fm175xx, timeout_ms: u32) TypeA.Error!void {
    if (timeout_ms == 0) return error.InvalidArgument;
    if (timeout_ms > TypeA.max_timeout_ms) return error.InvalidArgument;

    var prescaler: u32 = 0;
    var reload: u64 = 0;
    const timeout_ticks = @as(u64, timeout_ms) * 13560;
    while (prescaler < 0x0FFF) : (prescaler += 1) {
        reload = (timeout_ticks - 1) / (@as(u64, prescaler) * 2 + 1);
        if (reload < 0xFFFF) break;
    }

    reload &= 0xFFFF;
    _ = try self.setBitMask(regs.tmode, @truncate(prescaler >> 8));
    try self.writeByte(regs.tprescaler, @truncate(prescaler));
    try self.writeByte(regs.treload_hi, @truncate(reload >> 8));
    try self.writeByte(regs.treload_lo, @truncate(reload));
}

fn preCommand(self: *Fm175xx) TypeA.Error!void {
    try self.clearFifo();
    try self.writeByte(regs.command, regs.cmd_idle);
    try self.writeByte(regs.water_level, 0x20);
    try self.writeByte(regs.com_irq, 0x7F);
}

fn prepareExchange(self: *Fm175xx, exchange: TypeA.Exchange) TypeA.Error!void {
    if (exchange.tx_crc) {
        _ = try self.setBitMask(regs.tx_mode, regs.crc_enable);
    } else {
        _ = try self.clearBitMask(regs.tx_mode, regs.crc_enable);
    }

    if (exchange.rx_crc) {
        _ = try self.setBitMask(regs.rx_mode, regs.crc_enable);
    } else {
        _ = try self.clearBitMask(regs.rx_mode, regs.crc_enable);
    }

    _ = try self.clearBitMask(regs.status2, 0x08);
    try self.writeByte(regs.bit_framing, @truncate(exchange.tx_bits % 8));
    if (exchange.reset_collision) try self.writeByte(regs.coll, regs.reset_collision);
    try self.setTimer(exchange.timeout_ms);
}

fn finishCommand(self: *Fm175xx, maybe_err: ?TypeA.Error, out_bits: usize) TypeA.Error!usize {
    var final_err = maybe_err;

    if (final_err == null) {
        const chip_error = try self.readByte(regs.error_reg);
        if (chip_error != 0) final_err = error.Protocol;
    }

    _ = try self.setBitMask(regs.control, 0x80);
    try self.writeByte(regs.command, regs.cmd_idle);

    const framing = try self.readByte(regs.bit_framing);
    try self.writeByte(regs.bit_framing, framing & ~@as(u8, regs.start_send));

    if (final_err) |err| return err;
    return out_bits;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn openAndTypeAConfigureOverI2c() !void {
            const FakeI2c = struct {
                regs_map: [256]u8 = [_]u8{0} ** 256,
                writes: [32][2]u8 = undefined,
                write_count: usize = 0,

                pub fn write(self: *@This(), _: I2c.Address, data: []const u8) I2c.Error!void {
                    if (data.len >= 2) {
                        self.regs_map[data[0]] = data[1];
                        self.writes[self.write_count] = .{ data[0], data[1] };
                        self.write_count += 1;
                    }
                }

                pub fn read(self: *@This(), _: I2c.Address, buf: []u8) I2c.Error!void {
                    _ = self;
                    @memset(buf, 0);
                }

                pub fn writeRead(self: *@This(), _: I2c.Address, tx: []const u8, rx: []u8) I2c.Error!void {
                    if (tx.len == 0) return error.Unexpected;
                    rx[0] = self.regs_map[tx[0]];
                }
            };

            const FakeDelay = struct {
                last_sleep_ms: u32 = 0,
                pub fn sleepMs(self: *@This(), ms: u32) void {
                    self.last_sleep_ms = ms;
                }
            };

            const FakePower = struct {
                enabled: usize = 0,
                disabled: usize = 0,
                pub fn enable(self: *@This()) void {
                    self.enabled += 1;
                }
                pub fn disable(self: *@This()) void {
                    self.disabled += 1;
                }
            };

            var i2c = FakeI2c{};
            i2c.regs_map[regs.control] = 0x00;
            var delay = FakeDelay{};
            var power = FakePower{};

            var reader = Fm175xx.initI2c(I2c.init(&i2c), Delay.init(&delay), .{
                .address = 0x28,
                .power = Power.init(&power),
            });

            try reader.open();
            try reader.setIsoType(.a);

            try grt.std.testing.expectEqual(@as(usize, 1), power.enabled);
            try grt.std.testing.expectEqual(@as(u32, 100), delay.last_sleep_ms);
            try grt.std.testing.expectEqual(@as(u8, 0x00), i2c.regs_map[regs.tx_mode]);
            try grt.std.testing.expectEqual(@as(u8, 0x00), i2c.regs_map[regs.rx_mode]);
            try grt.std.testing.expectEqual(@as(u8, 0xF8), i2c.regs_map[regs.gsn]);
            try grt.std.testing.expectEqual(@as(u8, 0x3F), i2c.regs_map[regs.gwgsp]);
            try grt.std.testing.expectEqual(@as(u8, 0x68), i2c.regs_map[regs.rfcfg]);
            try grt.std.testing.expectEqual(@as(u8, 0x74), i2c.regs_map[regs.rx_thres]);
        }

        fn setRfValidatesReadback() !void {
            const FakeI2c = struct {
                regs_map: [256]u8 = [_]u8{0} ** 256,

                pub fn write(self: *@This(), _: I2c.Address, data: []const u8) I2c.Error!void {
                    if (data.len < 2) return;
                    if ((data[0] == regs.fifo_level) and (data[1] == 0x80)) {
                        self.regs_map[data[0]] = 0;
                        return;
                    }
                    self.regs_map[data[0]] = data[1];
                }

                pub fn read(self: *@This(), _: I2c.Address, buf: []u8) I2c.Error!void {
                    _ = self;
                    @memset(buf, 0);
                }

                pub fn writeRead(self: *@This(), _: I2c.Address, tx: []const u8, rx: []u8) I2c.Error!void {
                    if (tx[0] == regs.com_irq) {
                        rx[0] = 0;
                        return;
                    }
                    rx[0] = self.regs_map[tx[0]];
                }
            };

            const FakeDelay = struct {
                last_sleep_ms: u32 = 0,
                pub fn sleepMs(self: *@This(), ms: u32) void {
                    self.last_sleep_ms = ms;
                }
            };

            var i2c = FakeI2c{};
            i2c.regs_map[regs.tx_ctrl] = 0x80;
            var delay = FakeDelay{};
            var reader = Fm175xx.initI2c(I2c.init(&i2c), Delay.init(&delay), .{});

            try reader.setRf(.path2);
            try grt.std.testing.expectEqual(@as(u8, 0x82), i2c.regs_map[regs.tx_ctrl]);
            try grt.std.testing.expectEqual(@as(u32, 5), delay.last_sleep_ms);

            try grt.std.testing.expectError(error.UnsupportedOperation, reader.setIsoType(.b));
        }

        fn spiBackendFormatsRegisterAccess() !void {
            const FakeSpi = struct {
                last_tx_len: usize = 0,
                last_tx: [8]u8 = [_]u8{0} ** 8,
                call_index: usize = 0,

                pub fn write(self: *@This(), data: []const u8) Spi.Error!void {
                    self.last_tx_len = data.len;
                    @memcpy(self.last_tx[0..data.len], data);
                }

                pub fn transfer(self: *@This(), tx: []const u8, rx: []u8) Spi.Error!void {
                    self.last_tx_len = tx.len;
                    @memcpy(self.last_tx[0..tx.len], tx);
                    @memset(rx, 0);

                    switch (self.call_index) {
                        0 => rx[1] = 0x80,
                        2 => rx[1] = 0x81,
                        else => {},
                    }
                    self.call_index += 1;
                }
            };

            const FakeDelay = struct {
                pub fn sleepMs(_: *@This(), _: u32) void {}
            };

            var spi = FakeSpi{};
            var delay = FakeDelay{};
            var reader = Fm175xx.initSpi(Spi.init(&spi), Delay.init(&delay), .{});

            try reader.setRf(.path1);

            try grt.std.testing.expectEqual(@as(usize, 2), spi.last_tx_len);
            try grt.std.testing.expectEqualSlices(u8, &.{ (regs.tx_ctrl << 1) | 0x80, 0x00 }, spi.last_tx[0..2]);
        }

        fn transceiveReadsFifoAndReportsPartialBits() !void {
            const FakeI2c = struct {
                regs_map: [256]u8 = [_]u8{0} ** 256,
                com_irq_reads: usize = 0,
                fifo_level_reads: usize = 0,
                control_reads: usize = 0,

                pub fn write(self: *@This(), _: I2c.Address, data: []const u8) I2c.Error!void {
                    if (data.len < 2) return;
                    if ((data[0] == regs.fifo_level) and (data[1] == 0x80)) {
                        self.regs_map[data[0]] = 0;
                        return;
                    }
                    self.regs_map[data[0]] = data[1];
                }

                pub fn read(_: *@This(), _: I2c.Address, buf: []u8) I2c.Error!void {
                    @memset(buf, 0);
                }

                pub fn writeRead(self: *@This(), _: I2c.Address, tx: []const u8, rx: []u8) I2c.Error!void {
                    const addr = tx[0];
                    if (addr == regs.com_irq) {
                        rx[0] = if (self.com_irq_reads == 0) 0x04 else 0x20;
                        self.com_irq_reads += 1;
                        return;
                    }
                    if (addr == regs.fifo_level) {
                        rx[0] = if (self.fifo_level_reads < 2) 0 else 2;
                        self.fifo_level_reads += 1;
                        return;
                    }
                    if (addr == regs.control) {
                        rx[0] = if (self.control_reads == 0) 0x03 else self.regs_map[addr];
                        self.control_reads += 1;
                        return;
                    }
                    if (addr == regs.fifo_data) {
                        rx[0] = 0xAB;
                        if (rx.len > 1) rx[1] = 0xCD;
                        return;
                    }
                    rx[0] = self.regs_map[addr];
                }
            };

            const FakeDelay = struct {
                sleep_calls: usize = 0,
                pub fn sleepMs(self: *@This(), _: u32) void {
                    self.sleep_calls += 1;
                }
            };

            var i2c = FakeI2c{};
            var delay = FakeDelay{};
            var reader = Fm175xx.initI2c(I2c.init(&i2c), Delay.init(&delay), .{});

            var rx: [2]u8 = undefined;
            const bits = try reader.transceive(.{
                .tx = &.{0x26},
                .tx_bits = 7,
                .timeout_ms = 1,
            }, &rx);

            try grt.std.testing.expectEqual(@as(usize, 11), bits);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0xAB, 0xCD }, &rx);
            try grt.std.testing.expect(delay.sleep_calls >= 1);
        }

        fn transceiveUsesSoftwareTimeoutGuard() !void {
            const FakeI2c = struct {
                regs_map: [256]u8 = [_]u8{0} ** 256,

                pub fn write(self: *@This(), _: I2c.Address, data: []const u8) I2c.Error!void {
                    if (data.len < 2) return;
                    if ((data[0] == regs.fifo_level) and (data[1] == 0x80)) {
                        self.regs_map[data[0]] = 0;
                        return;
                    }
                    self.regs_map[data[0]] = data[1];
                }

                pub fn read(_: *@This(), _: I2c.Address, buf: []u8) I2c.Error!void {
                    @memset(buf, 0);
                }

                pub fn writeRead(self: *@This(), _: I2c.Address, tx: []const u8, rx: []u8) I2c.Error!void {
                    if (tx[0] == regs.com_irq) {
                        rx[0] = 0;
                        return;
                    }
                    rx[0] = self.regs_map[tx[0]];
                }
            };

            const FakeDelay = struct {
                sleep_calls: usize = 0,
                pub fn sleepMs(self: *@This(), _: u32) void {
                    self.sleep_calls += 1;
                }
            };

            var i2c = FakeI2c{};
            var delay = FakeDelay{};
            var reader = Fm175xx.initI2c(I2c.init(&i2c), Delay.init(&delay), .{});

            var rx: [1]u8 = undefined;
            try grt.std.testing.expectError(error.Timeout, reader.transceive(.{
                .tx = &.{0x26},
                .tx_bits = 7,
                .timeout_ms = 2,
            }, &rx));
            try grt.std.testing.expect(delay.sleep_calls >= 1);
        }

        fn transceiveRejectsInvalidExchangeInputs() !void {
            const FakeI2c = struct {
                pub fn write(_: *@This(), _: I2c.Address, _: []const u8) I2c.Error!void {}
                pub fn read(_: *@This(), _: I2c.Address, buf: []u8) I2c.Error!void {
                    @memset(buf, 0);
                }
                pub fn writeRead(_: *@This(), _: I2c.Address, _: []const u8, rx: []u8) I2c.Error!void {
                    @memset(rx, 0);
                }
            };

            const FakeDelay = struct {
                pub fn sleepMs(_: *@This(), _: u32) void {}
            };

            var i2c = FakeI2c{};
            var delay = FakeDelay{};
            var reader = Fm175xx.initI2c(I2c.init(&i2c), Delay.init(&delay), .{});
            var rx: [1]u8 = undefined;

            try grt.std.testing.expectError(error.InvalidArgument, reader.transceive(.{
                .tx = &.{0x26},
                .tx_bits = 7,
                .timeout_ms = 0,
            }, &rx));

            try grt.std.testing.expectError(error.InvalidArgument, reader.transceive(.{
                .tx = &.{0x26},
                .tx_bits = 7,
                .timeout_ms = TypeA.max_timeout_ms + 1,
            }, &rx));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.openAndTypeAConfigureOverI2c() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.setRfValidatesReadback() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.spiBackendFormatsRegisterAccess() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.transceiveReadsFifoAndReportsPartialBits() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.transceiveUsesSoftwareTimeoutGuard() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.transceiveRejectsInvalidExchangeInputs() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
