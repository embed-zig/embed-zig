const glib = @import("glib");
const binding = @import("std/thread/binding.zig");
const heap_binding = @import("std/heap/binding.zig");
const time_binding = @import("time/binding.zig");

pub const TaskRuntimeEntry = binding.TaskRuntimeEntry;

const max_cores = glib.system.max_cpu_cores;

const CpuSample = struct {
    initialized: bool = false,
    at_us: i64 = 0,
    core_count: usize = 0,
    idle_runtime: [max_cores]u64 = [_]u64{0} ** max_cores,
};

var cpu_sample: CpuSample = .{};

pub fn cpuCount() glib.system.CpuCountError!usize {
    const count = binding.espz_freertos_cpu_count();
    if (count == 0) return error.Unsupported;
    return count;
}

pub fn readCpuStats(out: *glib.system.CpuStats) glib.system.StatsError!void {
    out.* = .{};
    if (!binding.espz_freertos_idle_runtime_counter_supported()) {
        return error.Unsupported;
    }

    const count = @min(try cpuCount(), max_cores);
    out.core_count = count;

    var next = CpuSample{
        .initialized = true,
        .at_us = time_binding.espz_grt_time_uptime_us(),
        .core_count = count,
    };
    fillIdleRuntime(&next);

    if (cpu_sample.initialized and cpu_sample.core_count == count and next.at_us > cpu_sample.at_us) {
        const elapsed_us: u64 = @intCast(next.at_us - cpu_sample.at_us);
        if (elapsed_us != 0) {
            for (0..count) |i| {
                const idle_delta = saturatingSub(next.idle_runtime[i], cpu_sample.idle_runtime[i]);
                const bounded_idle_delta = @min(idle_delta, elapsed_us);
                const idle_percent = @divTrunc(bounded_idle_delta * 100, elapsed_us);
                out.cores[i].usage_percent = @intCast(100 - idle_percent);
            }
        }
    }

    cpu_sample = next;
}

pub fn readMemoryStats(out: *glib.system.MemoryStats) glib.system.StatsError!void {
    const default_caps = heap_binding.espz_heap_cap_default;
    const internal_caps = heap_binding.espz_heap_cap_internal | heap_binding.espz_heap_cap_8bit;
    const psram_caps = heap_binding.espz_heap_cap_spiram | heap_binding.espz_heap_cap_8bit;

    out.* = .{
        .heap_total = heap_binding.espz_heap_caps_get_total_size(default_caps),
        .heap_free = heap_binding.espz_heap_caps_get_free_size(default_caps),
        .heap_min_free = heap_binding.espz_heap_caps_get_minimum_free_size(default_caps),
        .internal_total = heap_binding.espz_heap_caps_get_total_size(internal_caps),
        .internal_free = heap_binding.espz_heap_caps_get_free_size(internal_caps),
        .internal_min_free = heap_binding.espz_heap_caps_get_minimum_free_size(internal_caps),
        .psram_total = heap_binding.espz_heap_caps_get_total_size(psram_caps),
        .psram_free = heap_binding.espz_heap_caps_get_free_size(psram_caps),
        .psram_min_free = heap_binding.espz_heap_caps_get_minimum_free_size(psram_caps),
    };
}

pub fn readTaskStats(out: *glib.system.TaskStats) glib.system.StatsError!void {
    out.* = .{
        .count = binding.espz_freertos_task_count(),
    };
}

pub fn taskRuntimeSnapshot(entries: []TaskRuntimeEntry) usize {
    if (entries.len == 0) return 0;
    const len = binding.espz_freertos_task_runtime_snapshot(entries.ptr, @intCast(entries.len));
    return @intCast(len);
}

fn fillIdleRuntime(sample: *CpuSample) void {
    for (0..sample.core_count) |core| {
        sample.idle_runtime[core] = binding.espz_freertos_idle_runtime_counter_for_core(@intCast(core));
    }
}

fn saturatingSub(a: u64, b: u64) u64 {
    return if (a > b) a - b else 0;
}
