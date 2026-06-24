const glib = @import("glib");

extern fn rtos_get_total_heap_size() usize;
extern fn rtos_get_free_heap_size() usize;
extern fn rtos_get_minimum_free_heap_size() usize;
extern fn rtos_get_psram_total_heap_size() usize;
extern fn rtos_get_psram_free_heap_size() usize;
extern fn rtos_get_psram_minimum_free_heap_size() usize;
extern fn uxTaskGetNumberOfTasks() usize;

pub fn cpuCount() glib.system.CpuCountError!usize {
    return 1;
}

pub fn readCpuStats(out: *glib.system.CpuStats) glib.system.StatsError!void {
    out.* = .{};
    return error.Unsupported;
}

pub fn readMemoryStats(out: *glib.system.MemoryStats) glib.system.StatsError!void {
    out.* = .{
        .heap_total = rtos_get_total_heap_size(),
        .heap_free = rtos_get_free_heap_size(),
        .heap_min_free = rtos_get_minimum_free_heap_size(),
        .internal_total = rtos_get_total_heap_size(),
        .internal_free = rtos_get_free_heap_size(),
        .internal_min_free = rtos_get_minimum_free_heap_size(),
        .psram_total = rtos_get_psram_total_heap_size(),
        .psram_free = rtos_get_psram_free_heap_size(),
        .psram_min_free = rtos_get_psram_minimum_free_heap_size(),
    };
}

pub fn readTaskStats(out: *glib.system.TaskStats) glib.system.StatsError!void {
    out.* = .{
        .count = uxTaskGetNumberOfTasks(),
    };
}
