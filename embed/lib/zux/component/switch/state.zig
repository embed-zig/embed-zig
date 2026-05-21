const drivers = @import("drivers");

pub const Switch = struct {
    enabled: bool = false,
};

pub const Pwm = struct {
    enabled: bool = false,
    frequency_hz: u32 = 0,
    duty: drivers.Pwm.Duty = .zero,
};
