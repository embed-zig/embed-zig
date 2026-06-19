const glib = @import("glib");
const binding = @import("std/thread/binding.zig");

pub fn cpuCount() glib.system.CpuCountError!usize {
    const count = binding.espz_freertos_cpu_count();
    if (count == 0) return error.Unsupported;
    return count;
}
