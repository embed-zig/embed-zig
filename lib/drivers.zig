//! drivers — categorized chip drivers and subsystem-local IO contracts.

pub const Adc = @import("drivers/Adc.zig");
pub const audio = @import("drivers/audio.zig");
pub const Delay = @import("drivers/Delay.zig");
pub const Display = @import("drivers/Display.zig");
pub const Gpio = @import("drivers/Gpio.zig");
pub const imu = @import("drivers/Imu.zig");
pub const I2c = @import("drivers/I2c.zig");
pub const gpio = Gpio;
pub const nfc = @import("drivers/Nfc.zig");
pub const button = @import("drivers/button.zig");
pub const Spi = @import("drivers/Spi.zig");
pub const wifi = @import("drivers/wifi.zig");

pub const Es7210 = audio.Es7210;
pub const Es8311 = audio.Es8311;
pub const Qmi8658 = imu.Qmi8658;
pub const Tca9554 = gpio.Tca9554;
pub const Fm175xx = nfc.Fm175xx;
pub const AdcButton = button.AdcButton;
pub const GpioButton = button.GpioButton;
pub const test_runner = struct {
    pub const unit = @import("drivers/test_runner/unit.zig");
};
