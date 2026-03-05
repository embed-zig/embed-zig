const esp = @import("esp");

pub const Driver = struct {
    ledc: esp.esp_driver_ledc.Ledc,
    duty: u16 = 0,
    wait_fade_done: bool = false,

    pub const Config = struct {
        gpio: i32 = 2,
        channel: i32 = 0,
        freq_hz: u32 = 1000,
        invert: bool = false,
        auto_install_fade: bool = true,
        wait_fade_done: bool = false,
    };

    pub fn init(cfg: Config) !Driver {
        const ledc = try esp.esp_driver_ledc.Ledc.init(.{
            .gpio = cfg.gpio,
            .channel = cfg.channel,
            .freq_hz = cfg.freq_hz,
            .invert = cfg.invert,
            .auto_install_fade = cfg.auto_install_fade,
        });
        return .{
            .ledc = ledc,
            .duty = 0,
            .wait_fade_done = cfg.wait_fade_done,
        };
    }

    pub fn setDuty(self: *Driver, duty: u16) void {
        self.duty = duty;
        const percent: u8 = @intCast((@as(u32, duty) * 100) / 65535);
        self.ledc.setDutyPercent(percent) catch {};
    }

    pub fn getDuty(self: *const Driver) u16 {
        return self.duty;
    }

    pub fn fade(self: *Driver, target: u16, duration_ms: u32) void {
        self.duty = target;
        const percent: u8 = @intCast((@as(u32, target) * 100) / 65535);
        self.ledc.fadeToPercent(percent, duration_ms, self.wait_fade_done) catch {
            // Fallback to immediate update if fade path is unavailable at runtime.
            self.ledc.setDutyPercent(percent) catch {};
        };
    }
};
