const std = @import("std");

pub fn now() u64 {
    var ns: std.os.wasi.timestamp_t = undefined;
    const rc = std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns);
    if (rc != .SUCCESS) unreachable;
    return ns;
}
