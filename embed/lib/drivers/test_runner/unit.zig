const glib = @import("glib");

const Adc = @import("../Adc.zig");
const Button = @import("../button.zig");
const Delay = @import("../Delay.zig");
const Gpio = @import("../Gpio.zig");
const I2c = @import("../I2c.zig");
const Spi = @import("../Spi.zig");
const Uart = @import("../Uart.zig");
const AdcButton = @import("../button/AdcButton.zig");
const Display = @import("../Display.zig");
const GpioButton = @import("../button/GpioButton.zig");
const Es7210 = @import("../audio/es7210.zig");
const Es8311 = @import("../audio/es8311.zig");
const Modem = @import("../Modem.zig");
const wifi = @import("../wifi.zig");
const Qmi8658 = @import("../imu/qmi8658.zig");
const Nfc = @import("../Nfc.zig");
const Tca9554 = @import("../gpio/tca9554.zig");
const TypeA = @import("../nfc/io/TypeA.zig");
const type_a = @import("../nfc/fm175xx/type_a.zig");
const ntag = @import("../nfc/fm175xx/ntag.zig");
const Fm175xx = @import("../nfc/fm175xx.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("Adc", Adc.TestRunner(grt));
            t.run("Button", Button.TestRunner(grt));
            t.run("Gpio", Gpio.TestRunner(grt));
            t.run("I2c", I2c.TestRunner(grt));
            t.run("Delay", Delay.TestRunner(grt));
            t.run("Spi", Spi.TestRunner(grt));
            t.run("Uart", Uart.TestRunner(grt));
            t.run("AdcButton", AdcButton.TestRunner(grt));
            t.run("Display", Display.TestRunner(grt));
            t.run("GpioButton", GpioButton.TestRunner(grt));
            t.run("Es7210", Es7210.TestRunner(grt));
            t.run("Es8311", Es8311.TestRunner(grt));
            t.run("Modem", Modem.TestRunner(grt));
            t.run("wifi", wifi.test_runner.unit.make(grt));
            t.run("Qmi8658", Qmi8658.TestRunner(grt));
            t.run("Nfc", Nfc.TestRunner(grt));
            t.run("Tca9554", Tca9554.TestRunner(grt));
            t.run("TypeA", TypeA.TestRunner(grt));
            t.run("type_a", type_a.TestRunner(grt));
            t.run("ntag", ntag.TestRunner(grt));
            t.run("Fm175xx", Fm175xx.TestRunner(grt));
            return t.wait();
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
