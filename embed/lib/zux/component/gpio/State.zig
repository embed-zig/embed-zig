const drivers = @import("drivers");

source_id: u32 = 0,
level: drivers.Gpio.Level = .low,
last_edge: ?drivers.Gpio.Edge = null,
generation: u64 = 0,
