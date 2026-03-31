//! drivers — categorized chip drivers and subsystem-local IO contracts.

pub const io = @import("drivers/io.zig");
pub const audio = @import("drivers/audio.zig");
pub const imu = @import("drivers/imu.zig");
pub const gpio = @import("drivers/gpio.zig");
pub const nfc = @import("drivers/nfc.zig");

pub const Es7210 = audio.Es7210;
pub const Es8311 = audio.Es8311;
pub const Qmi8658 = imu.Qmi8658;
pub const Tca9554 = gpio.Tca9554;
pub const Fm175xx = nfc.Fm175xx;

test "drivers/unit_tests" {
    _ = @import("drivers/io/I2c.zig");
    _ = @import("drivers/io/Delay.zig");
    _ = @import("drivers/io/Spi.zig");
    _ = @import("drivers/audio/es7210.zig");
    _ = @import("drivers/audio/es8311.zig");
    _ = @import("drivers/imu/qmi8658.zig");
    _ = @import("drivers/gpio/tca9554.zig");
    _ = @import("drivers/nfc/io/TypeA.zig");
    _ = @import("drivers/nfc/fm175xx.zig");
}
