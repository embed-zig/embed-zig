const std = @import("std");
const embed = struct {
    pub const hal = struct {
        pub const gpio = @import("../../hal/gpio.zig");
    };
};
const gpio_hal = embed.hal.gpio;
const RemoteHal = @import("../remote_hal.zig").RemoteHal;

const Error = gpio_hal.Error;
const Level = gpio_hal.Level;
const Mode = gpio_hal.Mode;
const Pull = gpio_hal.Pull;

pub const max_pins = 40;

pub const Gpio = struct {
    pins: [max_pins]std.atomic.Value(u8) = [_]std.atomic.Value(u8){.{ .raw = @intFromEnum(Level.high) }} ** max_pins,
    vcc: f32 = 3.3,

    pub fn init() Gpio {
        return .{};
    }

    pub fn deinit(_: *Gpio) void {}

    pub fn registerOn(self: *Gpio, bus: *RemoteHal) void {
        bus.register("gpio", @ptrCast(self), &onBusEvent);
    }

    fn onBusEvent(ctx: *anyopaque, obj: std.json.ObjectMap) void {
        const self: *Gpio = @ptrCast(@alignCast(ctx));

        const pin: u8 = switch (obj.get("pin") orelse return) {
            .integer => |v| if (v >= 0 and v < max_pins) @intCast(v) else return,
            else => return,
        };

        const voltage: f32 = switch (obj.get("voltage") orelse return) {
            .float => |v| @floatCast(v),
            .integer => |v| @floatFromInt(v),
            else => return,
        };

        const threshold = self.vcc / 2.0;
        const level: Level = if (voltage > threshold) .high else .low;
        self.injectLevel(pin, level);
    }

    pub fn setMode(_: *Gpio, pin: u8, _: Mode) Error!void {
        if (pin >= max_pins) return error.InvalidPin;
    }

    pub fn setLevel(self: *Gpio, pin: u8, level: Level) Error!void {
        if (pin >= max_pins) return error.InvalidPin;
        self.pins[pin].store(@intFromEnum(level), .release);
    }

    pub fn getLevel(self: *Gpio, pin: u8) Error!Level {
        if (pin >= max_pins) return error.InvalidPin;
        return @enumFromInt(self.pins[pin].load(.acquire));
    }

    pub fn setPull(_: *Gpio, pin: u8, _: Pull) Error!void {
        if (pin >= max_pins) return error.InvalidPin;
    }

    pub fn injectLevel(self: *Gpio, pin: u8, level: Level) void {
        if (pin >= max_pins) return;
        self.pins[pin].store(@intFromEnum(level), .release);
    }
};

test "websim gpio satisfies hal contract" {
    const GpioHal = gpio_hal.from(struct {
        pub const Driver = Gpio;
        pub const meta = .{ .id = "gpio.websim" };
    });

    var drv = Gpio.init();
    var g = GpioHal.init(&drv);
    try g.configure(0, .{ .mode = .input });
    try std.testing.expectEqual(Level.high, try g.getLevel(0));

    drv.injectLevel(0, .low);
    try std.testing.expectEqual(Level.low, try g.getLevel(0));

    drv.injectLevel(0, .high);
    try std.testing.expectEqual(Level.high, try g.getLevel(0));
}

test "websim gpio rejects invalid pin" {
    var drv = Gpio.init();
    try std.testing.expectError(error.InvalidPin, drv.getLevel(max_pins));
    try std.testing.expectError(error.InvalidPin, drv.setLevel(max_pins, .high));
}
