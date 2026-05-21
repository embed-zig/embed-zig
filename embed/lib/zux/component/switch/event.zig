const drivers = @import("drivers");

pub const Set = struct {
    pub const kind = .switch_set;

    source_id: u32,
    enabled: bool,
};

pub const PwmSet = struct {
    pub const kind = .pwm_set;

    source_id: u32,
    enabled: bool,
    frequency_hz: u32,
    duty: drivers.Pwm.Duty,
};
