const std = @import("std");

pub fn now() u64 {
    const value, _ = std.os.uefi.system_table.runtime_services.getTime() catch unreachable;
    return value.toEpoch();
}
