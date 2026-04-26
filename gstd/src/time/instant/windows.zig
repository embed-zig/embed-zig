const std = @import("std");

const windows = std.os.windows;

const ns_per_s = 1_000_000_000;

pub fn now() u64 {
    return qpcToNs(windows.QueryPerformanceCounter());
}

fn qpcToNs(qpc: u64) u64 {
    const qpf = windows.QueryPerformanceFrequency();
    const common_qpf = 10_000_000;

    if (qpf == common_qpf) {
        return qpc * (ns_per_s / common_qpf);
    }

    const scale = (@as(u64, ns_per_s) << 32) / @as(u32, @intCast(qpf));
    const result = (@as(u96, qpc) * scale) >> 32;
    return @truncate(result);
}
