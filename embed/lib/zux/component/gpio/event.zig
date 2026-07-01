const drivers = @import("drivers");

pub const RawChanged = struct {
    pub const kind = .raw_gpio_changed;

    source_id: u32,
    edge: drivers.Gpio.Edge,
    level: drivers.Gpio.Level,
};
