const std = @import("std");
const esp = @import("esp");
const hal_rtc = @import("hal").rtc;

/// RTC driver backed by esp_timer uptime plus a software epoch anchor.
///
/// - `uptime()` is always available (ms since boot)
/// - `nowMs()` becomes available after first `setNowMs()`
pub const Driver = struct {
    base_uptime_ms: u64 = 0,
    base_epoch_ms: i64 = 0,
    synced: bool = false,

    pub fn uptime(_: *Driver) u64 {
        return esp.esp_timer.getTimeMs();
    }

    pub fn nowMs(self: *Driver) ?i64 {
        if (!self.synced) return null;

        const now_uptime = esp.esp_timer.getTimeMs();
        const delta_u64 = now_uptime -% self.base_uptime_ms;
        const delta_i64 = std.math.cast(i64, delta_u64) orelse return null;

        const sum = @addWithOverflow(self.base_epoch_ms, delta_i64);
        if (sum[1] != 0) return null;
        return sum[0];
    }

    pub fn setNowMs(self: *Driver, epoch_ms: i64) hal_rtc.WriterError!void {
        self.base_uptime_ms = esp.esp_timer.getTimeMs();
        self.base_epoch_ms = epoch_ms;
        self.synced = true;
    }
};
