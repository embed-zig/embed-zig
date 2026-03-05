const esp = @import("esp");

pub const Time = struct {
    pub fn nowMs(_: Time) u64 {
        return esp.esp_timer.getTimeMs();
    }

    pub fn sleepMs(_: Time, ms: u32) void {
        esp.freertos.delay(esp.freertos.msToTicks(ms, tick_rate_hz));
    }

    const tick_rate_hz: u32 = 100;
};
