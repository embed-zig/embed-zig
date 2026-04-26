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

pub fn make(comptime lib: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("Adc", Adc.TestRunner(lib));
            t.run("Button", Button.TestRunner(lib));
            t.run("Gpio", Gpio.TestRunner(lib));
            t.run("I2c", I2c.TestRunner(lib));
            t.run("Delay", Delay.TestRunner(lib));
            t.run("Spi", Spi.TestRunner(lib));
            t.run("Uart", Uart.TestRunner(lib));
            t.run("AdcButton", AdcButton.TestRunner(lib));
            t.run("Display", Display.TestRunner(lib));
            t.run("GpioButton", GpioButton.TestRunner(lib));
            t.run("Es7210", Es7210.TestRunner(lib));
            t.run("Es8311", Es8311.TestRunner(lib));
            t.run("Modem", Modem.TestRunner(lib));
            t.run("wifi", wifi.test_runner.unit.make(lib));
            t.run("Qmi8658", Qmi8658.TestRunner(lib));
            t.run("Nfc", Nfc.TestRunner(lib));
            t.run("Tca9554", Tca9554.TestRunner(lib));
            t.run("TypeA", TypeA.TestRunner(lib));
            t.run("type_a", type_a.TestRunner(lib));
            t.run("ntag", ntag.TestRunner(lib));
            t.run("Fm175xx", Fm175xx.TestRunner(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
