//! PCA9557 I2C GPIO Expander Driver
//!
//! Platform-independent driver for NXP PCA9557-compatible 8-bit I/O expanders.
//!
//! Features:
//! - 8 GPIO pins, addressed as pins or masks
//! - Configurable input/output direction
//! - Output latch caching for read-modify-write updates
//! - Polarity inversion for input pins
//!
//! Local docs:
//! - `lib/drivers/gpio/pca9557.md`
//! - `lib/drivers/gpio/pca9557.pdf`

const glib = @import("glib");
const I2c = @import("../I2c.zig");

const pca9557 = @This();

pub const Register = enum(u8) {
    input = 0x00,
    output = 0x01,
    polarity = 0x02,
    config = 0x03,
};

pub const Defaults = struct {
    pub const INPUT: u8 = 0xFF;
    pub const OUTPUT: u8 = 0xFF;
    pub const POLARITY: u8 = 0x00;
    pub const CONFIG: u8 = 0xFF;
};

pub const Address = struct {
    pub const BASE: u7 = 0x18;

    pub fn fromPins(a2: bool, a1: bool, a0: bool) u7 {
        return BASE |
            (if (a0) @as(u7, 0x01) else 0) |
            (if (a1) @as(u7, 0x02) else 0) |
            (if (a2) @as(u7, 0x04) else 0);
    }
};

pub const PinMask = struct {
    pub const NONE: u8 = 0x00;
    pub const ALL: u8 = 0xFF;
    pub const LOW_NIBBLE: u8 = 0x0F;
    pub const HIGH_NIBBLE: u8 = 0xF0;
};

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

pub const Direction = enum(u1) {
    output = 0,
    input = 1,
};

pub const Level = enum(u1) {
    low = 0,
    high = 1,
};

const Self = @This();

i2c: I2c,
address: u7,
output_cache: u8 = Defaults.OUTPUT,
config_cache: u8 = Defaults.CONFIG,

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

pub fn configureOutput(self: *Self, pin: Pin, initial: Level) !void {
    try self.write(pin, initial);
    try self.setDirection(pin, .output);
}

pub fn configureInput(self: *Self, pin: Pin) !void {
    try self.setDirection(pin, .input);
}

pub fn configureMultiple(self: *Self, output_pins: u8, initial_levels: u8) !void {
    self.output_cache = initial_levels;
    self.config_cache = ~output_pins;
    try self.writeRegister(.output, self.output_cache);
    try self.writeRegister(.config, self.config_cache);
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
    return if ((self.config_cache & pin.mask()) != 0) .input else .output;
}

pub fn getOutput(self: *Self, pin: Pin) Level {
    return if ((self.output_cache & pin.mask()) != 0) .high else .low;
}

pub fn getOutputAll(self: *Self) u8 {
    return self.output_cache;
}

pub fn getConfigAll(self: *Self) u8 {
    return self.config_cache;
}

pub fn setAllOutputs(self: *Self) !void {
    self.config_cache = PinMask.NONE;
    try self.writeRegister(.config, self.config_cache);
}

pub fn setAllInputs(self: *Self) !void {
    self.config_cache = PinMask.ALL;
    try self.writeRegister(.config, self.config_cache);
}

pub fn setHigh(self: *Self, pin: Pin) !void {
    try self.write(pin, .high);
}

pub fn setLow(self: *Self, pin: Pin) !void {
    try self.write(pin, .low);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn configureMultipleWritesOutputThenConfig() !void {
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
            var gpio = pca9557.init(I2c.init(&fake), Address.fromPins(false, false, true));

            try gpio.configureMultiple(0x07, 0x05);
            try gpio.setHigh(.pin1);

            try grt.std.testing.expectEqual(@as(usize, 3), fake.write_count);
            try grt.std.testing.expectEqual([2]u8{ @intFromEnum(Register.output), 0x05 }, fake.writes[0]);
            try grt.std.testing.expectEqual([2]u8{ @intFromEnum(Register.config), 0xF8 }, fake.writes[1]);
            try grt.std.testing.expectEqual([2]u8{ @intFromEnum(Register.output), 0x07 }, fake.writes[2]);
            try grt.std.testing.expectEqual(@as(u8, 0x07), gpio.getOutputAll());
            try grt.std.testing.expectEqual(@as(u8, 0xF8), gpio.getConfigAll());
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

            TestCase.configureMultipleWritesOutputThenConfig() catch |err| {
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
