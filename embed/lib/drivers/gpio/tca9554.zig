//! TCA9554 / TCA9554A I2C GPIO Expander Driver
//!
//! Platform-independent driver for Texas Instruments TCA9554/TCA9554A
//! 8-bit I2C I/O expander with interrupt output.
//!
//! Features:
//! - 8 GPIO pins (directly addressable or as bitmask)
//! - Configurable as input or output
//! - Polarity inversion for inputs
//! - Optional interrupt on input change
//!
//! Local docs:
//! - `lib/drivers/gpio/tca9554.md`
//! - `lib/drivers/gpio/tca9554.pdf`
//!
//! Usage:
//!   var gpio = drivers.gpio.Tca9554.init(drivers.I2c.init(&my_i2c), 0x20);
//!   try gpio.setDirection(.pin6, .output);
//!   try gpio.write(.pin6, .high);

const glib = @import("glib");
const I2c = @import("../I2c.zig");

const tca9554 = @This();

/// TCA9554 register addresses
pub const Register = enum(u8) {
    input = 0x00,
    output = 0x01,
    polarity = 0x02,
    config = 0x03,
};

// ============================================================================
// Register Bit Field Constants
// ============================================================================

/// Default register values after power-on reset
pub const Defaults = struct {
    pub const INPUT: u8 = 0xFF;
    pub const OUTPUT: u8 = 0xFF;
    pub const POLARITY: u8 = 0x00;
    pub const CONFIG: u8 = 0xFF;
};

/// Common I2C addresses
pub const Address = struct {
    pub const TCA9554_BASE: u7 = 0x20;
    pub const TCA9554A_BASE: u7 = 0x38;
};

/// Pin masks for common use cases
pub const PinMask = struct {
    pub const NONE: u8 = 0x00;
    pub const ALL: u8 = 0xFF;
    pub const LOW_NIBBLE: u8 = 0x0F;
    pub const HIGH_NIBBLE: u8 = 0xF0;
};

/// GPIO pin identifiers
pub const Pin = enum(u3) {
    pin0 = 0,
    pin1 = 1,
    pin2 = 2,
    pin3 = 3,
    pin4 = 4,
    pin5 = 5,
    pin6 = 6,
    pin7 = 7,

    pub fn mask(self: Pin) u8 {
        return @as(u8, 1) << @intFromEnum(self);
    }
};

/// Pin direction
pub const Direction = enum(u1) {
    output = 0,
    input = 1,
};

/// Pin level
pub const Level = enum(u1) {
    low = 0,
    high = 1,
};

// ============================================================================
// Driver Implementation
// ============================================================================

/// TCA9554 GPIO Expander Driver using `drivers.I2c`.
const Self = @This();

i2c: I2c,
address: u7,

output_cache: u8 = 0xFF,
config_cache: u8 = 0xFF,

pub fn init(i2c: I2c, address: u7) Self {
    return .{
        .i2c = i2c,
        .address = address,
    };
}

pub fn readRegister(self: *Self, reg: Register) !u8 {
    var buf: [1]u8 = undefined;
    try self.i2c.writeRead(self.address, &.{@intFromEnum(reg)}, &buf);
    return buf[0];
}

pub fn writeRegister(self: *Self, reg: Register, value: u8) !void {
    try self.i2c.write(self.address, &.{ @intFromEnum(reg), value });
}

// ====================================================================
// High-level API
// ====================================================================

pub fn setDirection(self: *Self, pin: Pin, dir: Direction) !void {
    const m = pin.mask();
    if (dir == .output) {
        self.config_cache &= ~m;
    } else {
        self.config_cache |= m;
    }
    try self.writeRegister(.config, self.config_cache);
}

pub fn setDirectionMask(self: *Self, output_mask: u8) !void {
    self.config_cache = ~output_mask;
    try self.writeRegister(.config, self.config_cache);
}

pub fn write(self: *Self, pin: Pin, level: Level) !void {
    const m = pin.mask();
    if (level == .high) {
        self.output_cache |= m;
    } else {
        self.output_cache &= ~m;
    }
    try self.writeRegister(.output, self.output_cache);
}

pub fn writeMask(self: *Self, m: u8, levels: u8) !void {
    self.output_cache = (self.output_cache & ~m) | (levels & m);
    try self.writeRegister(.output, self.output_cache);
}

pub fn writeAll(self: *Self, value: u8) !void {
    self.output_cache = value;
    try self.writeRegister(.output, value);
}

pub fn read(self: *Self, pin: Pin) !Level {
    const value = try self.readRegister(.input);
    return if ((value & pin.mask()) != 0) .high else .low;
}

pub fn readAll(self: *Self) !u8 {
    return try self.readRegister(.input);
}

pub fn toggle(self: *Self, pin: Pin) !void {
    self.output_cache ^= pin.mask();
    try self.writeRegister(.output, self.output_cache);
}

pub fn setPolarity(self: *Self, pin: Pin, inverted: bool) !void {
    var polarity = try self.readRegister(.polarity);
    const m = pin.mask();
    if (inverted) {
        polarity |= m;
    } else {
        polarity &= ~m;
    }
    try self.writeRegister(.polarity, polarity);
}

// ====================================================================
// Convenience functions
// ====================================================================

pub fn configureOutput(self: *Self, pin: Pin, initial: Level) !void {
    try self.write(pin, initial);
    try self.setDirection(pin, .output);
}

pub fn configureInput(self: *Self, pin: Pin) !void {
    try self.setDirection(pin, .input);
}

pub fn reset(self: *Self) !void {
    self.output_cache = Defaults.OUTPUT;
    self.config_cache = Defaults.CONFIG;
    try self.writeRegister(.output, Defaults.OUTPUT);
    try self.writeRegister(.polarity, Defaults.POLARITY);
    try self.writeRegister(.config, Defaults.CONFIG);
}

pub fn syncFromDevice(self: *Self) !void {
    self.config_cache = try self.readRegister(.config);
    self.output_cache = try self.readRegister(.output);
}

pub fn getDirection(self: *Self, pin: Pin) Direction {
    const m = pin.mask();
    return if ((self.config_cache & m) != 0) .input else .output;
}

pub fn getOutput(self: *Self, pin: Pin) Level {
    const m = pin.mask();
    return if ((self.output_cache & m) != 0) .high else .low;
}

pub fn getOutputAll(self: *Self) u8 {
    return self.output_cache;
}

pub fn getConfigAll(self: *Self) u8 {
    return self.config_cache;
}

pub fn isOutput(self: *Self, pin: Pin) bool {
    return self.getDirection(pin) == .output;
}

pub fn isInput(self: *Self, pin: Pin) bool {
    return self.getDirection(pin) == .input;
}

pub fn setAllOutputs(self: *Self) !void {
    self.config_cache = PinMask.NONE;
    try self.writeRegister(.config, self.config_cache);
}

pub fn setAllInputs(self: *Self) !void {
    self.config_cache = PinMask.ALL;
    try self.writeRegister(.config, self.config_cache);
}

pub fn setAllHigh(self: *Self) !void {
    self.output_cache = PinMask.ALL;
    try self.writeRegister(.output, self.output_cache);
}

pub fn setAllLow(self: *Self) !void {
    self.output_cache = PinMask.NONE;
    try self.writeRegister(.output, self.output_cache);
}

pub fn setPolarityMask(self: *Self, invert_mask: u8) !void {
    try self.writeRegister(.polarity, invert_mask);
}

pub fn getPolarity(self: *Self) !u8 {
    return try self.readRegister(.polarity);
}

pub fn configureMultiple(self: *Self, output_pins: u8, initial_levels: u8) !void {
    self.output_cache = initial_levels;
    self.config_cache = ~output_pins;
    try self.writeRegister(.output, self.output_cache);
    try self.writeRegister(.config, self.config_cache);
}

pub fn pulse(self: *Self, pin: Pin) !void {
    try self.toggle(pin);
    try self.toggle(pin);
}

pub fn setHigh(self: *Self, pin: Pin) !void {
    try self.write(pin, .high);
}

pub fn setLow(self: *Self, pin: Pin) !void {
    try self.write(pin, .low);
}

pub fn isHigh(self: *Self, pin: Pin) !bool {
    return (try self.read(pin)) == .high;
}

pub fn isLow(self: *Self, pin: Pin) !bool {
    return (try self.read(pin)) == .low;
}
pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn setDirectionAndWriteUpdateCachedRegisters() !void {
            const FakeI2c = struct {
                writes: [4][2]u8 = [_][2]u8{[_]u8{ 0, 0 }} ** 4,
                write_count: usize = 0,

                pub fn write(self: *@This(), _: I2c.Address, data: []const u8) I2c.Error!void {
                    self.writes[self.write_count] = .{ data[0], data[1] };
                    self.write_count += 1;
                }

                pub fn read(self: *@This(), _: I2c.Address, _: []u8) I2c.Error!void {
                    _ = self;
                    return error.Unexpected;
                }

                pub fn writeRead(self: *@This(), _: I2c.Address, _: []const u8, _: []u8) I2c.Error!void {
                    _ = self;
                    return error.Unexpected;
                }
            };

            var fake = FakeI2c{};
            var gpio = tca9554.init(I2c.init(&fake), Address.TCA9554_BASE);

            try gpio.setDirection(.pin6, .output);
            try gpio.write(.pin6, .low);

            try grt.std.testing.expectEqual(@as(usize, 2), fake.write_count);
            try grt.std.testing.expectEqual([2]u8{ @intFromEnum(Register.config), 0xBF }, fake.writes[0]);
            try grt.std.testing.expectEqual([2]u8{ @intFromEnum(Register.output), 0xBF }, fake.writes[1]);
            try grt.std.testing.expectEqual(@as(u8, 0xBF), gpio.getConfigAll());
            try grt.std.testing.expectEqual(@as(u8, 0xBF), gpio.getOutputAll());
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

            TestCase.setDirectionAndWriteUpdateCachedRegisters() catch |err| {
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
