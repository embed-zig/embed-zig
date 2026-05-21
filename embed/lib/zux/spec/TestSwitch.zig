const drivers = @import("drivers");

pub const Switch = struct {
    const Self = @This();

    pub const State = struct {
        set_count: usize = 0,
        enabled: bool = false,
    };

    state: State = .{},

    pub fn reset(self: *Self) void {
        self.state = .{};
    }

    pub fn api(self: *Self) drivers.Switch {
        return drivers.Switch.init(self);
    }

    pub fn set(self: *Self, enabled: bool) drivers.Switch.Error!void {
        self.state.set_count += 1;
        self.state.enabled = enabled;
    }

    pub fn get(self: *Self) drivers.Switch.Error!bool {
        return self.state.enabled;
    }
};

pub const Pwm = struct {
    const Self = @This();

    pub const State = struct {
        frequency_hz: u32 = 0,
        duty_numerator: u32 = 0,
        duty_denominator: u32 = 1,
        enabled: bool = false,
        set_frequency_count: usize = 0,
        set_duty_count: usize = 0,
        enable_count: usize = 0,
        disable_count: usize = 0,
    };

    state: State = .{},

    pub fn reset(self: *Self) void {
        self.state = .{};
    }

    pub fn api(self: *Self) drivers.Pwm {
        return drivers.Pwm.init(self);
    }

    pub fn setFrequencyHz(self: *Self, hz: u32) drivers.Pwm.Error!void {
        self.state.set_frequency_count += 1;
        self.state.frequency_hz = hz;
    }

    pub fn setDuty(self: *Self, duty: drivers.Pwm.Duty) drivers.Pwm.Error!void {
        self.state.set_duty_count += 1;
        self.state.duty_numerator = duty.numerator;
        self.state.duty_denominator = duty.denominator;
    }

    pub fn enable(self: *Self) drivers.Pwm.Error!void {
        self.state.enable_count += 1;
        self.state.enabled = true;
    }

    pub fn disable(self: *Self) drivers.Pwm.Error!void {
        self.state.disable_count += 1;
        self.state.enabled = false;
    }
};
