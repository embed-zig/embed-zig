const std = @import("std");
const testing = std.testing;
const module = @import("gpio.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const gpio_hal = @import("../../hal/gpio.zig");
const Level = gpio_hal.Level;
const max_pins = module.max_pins;
const Gpio = module.Gpio;

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
