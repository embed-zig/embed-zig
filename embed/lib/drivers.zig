//! drivers — categorized chip drivers and subsystem-local IO contracts.

pub const Adc = @import("drivers/Adc.zig");
pub const audio = @import("drivers/audio.zig");
pub const Delay = @import("drivers/Delay.zig");
pub const Display = @import("drivers/Display.zig");
pub const Dbi = @import("drivers/display/Dbi.zig");
pub const Gpio = @import("drivers/Gpio.zig");
pub const imu = @import("drivers/Imu.zig");
pub const I2c = @import("drivers/I2c.zig");
pub const I2s = @import("drivers/I2s.zig");
pub const Modem = @import("drivers/Modem.zig");
const switch_mod = @import("drivers/switch.zig");
pub const Uart = @import("drivers/Uart.zig");
pub const gpio = Gpio;
pub const nfc = @import("drivers/Nfc.zig");
pub const button = @import("drivers/button.zig");
pub const Spi = @import("drivers/Spi.zig");
pub const Touch = @import("drivers/Touch.zig");
pub const wifi = @import("drivers/wifi.zig");

pub const Es7210 = audio.Es7210;
pub const Es8311 = audio.Es8311;
pub const Qmi8658 = imu.Qmi8658;
pub const Pca9557 = gpio.Pca9557;
pub const Tca9554 = gpio.Tca9554;
pub const Fm175xx = nfc.Fm175xx;
pub const AdcButton = button.AdcButton;
pub const GpioButton = button.GpioButton;
pub const Ft5x06 = Touch.Ft5x06;
pub const Gt911 = Touch.Gt911;
pub const Switch = switch_mod.Switch;
pub const Pwm = switch_mod.Pwm;
pub const test_runner = struct {
    pub const unit = @import("drivers/test_runner/unit.zig");
    pub const integration = @import("drivers/test_runner/integration.zig");
};
