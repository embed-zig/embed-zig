const glib = @import("glib");
const binding = @import("binding.zig");

const ns_per_s: u64 = @intCast(glib.time.duration.Second);

pub fn sleep(ns: u64) void {
    sleepTicks(nsToTicksCeil(ns));
}

pub fn sleepTicks(ticks: u32) void {
    if (ticks == 0) return;
    binding.espz_freertos_task_delay(ticks);
}

fn nsToTicksCeil(ns: u64) u32 {
    if (ns == 0) return 0;

    const tick_rate_hz = binding.espz_freertos_tick_rate_hz();
    if (tick_rate_hz == 0) return glib.std.math.maxInt(u32);

    const whole_seconds = ns / ns_per_s;
    if (whole_seconds > glib.std.math.maxInt(u32) / tick_rate_hz) return glib.std.math.maxInt(u32);

    const remainder_ns = ns % ns_per_s;
    const whole_ticks = whole_seconds * tick_rate_hz;
    const remainder_ticks = ceilDiv(remainder_ns * tick_rate_hz, ns_per_s);
    const ticks = whole_ticks + remainder_ticks;
    if (ticks > glib.std.math.maxInt(u32)) return glib.std.math.maxInt(u32);
    return @intCast(ticks);
}

fn ceilDiv(numerator: u64, denominator: u64) u64 {
    if (numerator == 0) return 0;
    return ((numerator - 1) / denominator) + 1;
}
