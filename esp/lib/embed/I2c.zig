const embed = @import("embed");

pub const Error = embed.drivers.I2c.Error;
pub const Address = embed.drivers.I2c.Address;

pub const MasterBus = @import("i2c/MasterBus.zig");
pub const Config = MasterBus.Config;
