const esp = @import("esp");
const hal_pwm = @import("hal").pwm;

const max_channels: usize = 8;
const full_scale: u32 = 65535;

pub const Driver = struct {
    gpio_by_channel: [max_channels]i32 = [_]i32{-1} ** max_channels,
    inited: [max_channels]bool = [_]bool{false} ** max_channels,
    freq_hz: [max_channels]u32 = [_]u32{1000} ** max_channels,
    duty: [max_channels]u16 = [_]u16{0} ** max_channels,

    pub fn init() hal_pwm.Error!Driver {
        return .{};
    }

    pub fn initChannel(self: *Driver, channel: u8, gpio: i32, freq_hz: u32) hal_pwm.Error!void {
        const idx = channelIndex(channel) orelse return error.InvalidChannel;
        self.gpio_by_channel[idx] = gpio;
        self.freq_hz[idx] = freq_hz;
        try ensureInited(self, idx);
    }

    pub fn setDuty(self: *Driver, channel: u8, duty: u16) hal_pwm.Error!void {
        const idx = channelIndex(channel) orelse return error.InvalidChannel;
        try ensureInited(self, idx);
        self.duty[idx] = duty;

        const percent: u8 = @intCast((@as(u32, duty) * 100) / full_scale);
        esp.esp_driver_ledc.setDutyPercent(@intCast(channel), percent) catch return error.PwmError;
    }

    pub fn getDuty(self: *Driver, channel: u8) hal_pwm.Error!u16 {
        const idx = channelIndex(channel) orelse return error.InvalidChannel;
        return self.duty[idx];
    }

    pub fn setFrequency(self: *Driver, channel: u8, hz: u32) hal_pwm.Error!void {
        const idx = channelIndex(channel) orelse return error.InvalidChannel;
        if (hz == 0) return error.PwmError;
        self.freq_hz[idx] = hz;
        try ensureInited(self, idx);
    }
};

fn channelIndex(channel: u8) ?usize {
    if (channel >= max_channels) return null;
    return channel;
}

fn ensureInited(self: *Driver, idx: usize) hal_pwm.Error!void {
    if (self.inited[idx]) return;

    const gpio = if (self.gpio_by_channel[idx] >= 0) self.gpio_by_channel[idx] else @as(i32, @intCast(idx));
    esp.esp_driver_ledc.backlightInit(gpio, @intCast(idx), self.freq_hz[idx], false) catch return error.PwmError;
    self.inited[idx] = true;
}
