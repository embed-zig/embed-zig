const glib = @import("glib");
const binding = @import("std/thread/binding.zig");

pub const TaskRuntimeEntry = binding.TaskRuntimeEntry;

pub fn cpuCount() glib.system.CpuCountError!usize {
    const count = binding.espz_freertos_cpu_count();
    if (count == 0) return error.Unsupported;
    return count;
}

pub fn taskRuntimeSnapshot(entries: []TaskRuntimeEntry) usize {
    if (entries.len == 0) return 0;
    const len = binding.espz_freertos_task_runtime_snapshot(entries.ptr, @intCast(entries.len));
    return @intCast(len);
}
