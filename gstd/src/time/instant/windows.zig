const std = @import("std");
const glib = @import("glib");

const windows = std.os.windows;

pub fn now() u64 {
    return qpcToNs(windows.QueryPerformanceCounter());
}

fn qpcToNs(qpc: u64) u64 {
    const qpf = windows.QueryPerformanceFrequency();
    const common_qpf = 10_000_000;

    if (qpf == common_qpf) {
        return qpc * (@as(u64, @intCast(glib.time.duration.Second)) / common_qpf);
    }

    const scale = (@as(u64, @intCast(glib.time.duration.Second)) << 32) / @as(u32, @intCast(qpf));
    const result = (@as(u96, qpc) * scale) >> 32;
    return @truncate(result);
}
