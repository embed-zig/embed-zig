//! system — runtime/system information contract.

const cpu_mod = @import("system/cpu.zig");

const system = @This();

pub const cpu = cpu_mod;
pub const CpuCountError = cpu_mod.CpuCountError;
pub const StatsError = error{
    Unsupported,
    PermissionDenied,
    SystemResources,
    Unexpected,
};
pub const max_cpu_cores = 8;

pub const CpuStats = struct {
    core_count: usize = 0,
    cores: [max_cpu_cores]Core = [_]Core{.{}} ** max_cpu_cores,

    pub const Core = struct {
        usage_percent: u8 = 0,
    };
};

pub const MemoryStats = struct {
    heap_total: usize = 0,
    heap_free: usize = 0,
    heap_min_free: usize = 0,
    internal_total: usize = 0,
    internal_free: usize = 0,
    internal_min_free: usize = 0,
    psram_total: usize = 0,
    psram_free: usize = 0,
    psram_min_free: usize = 0,
};

pub const TaskStats = struct {
    count: usize = 0,
};

pub fn make(comptime Impl: type) type {
    const RuntimeCpu = cpu_mod.make(Impl);

    return struct {
        pub const CpuCountError = cpu_mod.CpuCountError;
        pub const StatsError = system.StatsError;
        pub const CpuStats = system.CpuStats;
        pub const MemoryStats = system.MemoryStats;
        pub const TaskStats = system.TaskStats;
        pub const max_cpu_cores = system.max_cpu_cores;
        pub const cpu = RuntimeCpu;

        pub fn cpuCount() cpu_mod.CpuCountError!usize {
            return RuntimeCpu.cpuCount();
        }

        pub fn readCpuStats(out: *system.CpuStats) system.StatsError!void {
            if (comptime @hasDecl(Impl, "readCpuStats")) {
                return Impl.readCpuStats(out);
            }
            out.* = .{};
            return error.Unsupported;
        }

        pub fn readMemoryStats(out: *system.MemoryStats) system.StatsError!void {
            if (comptime @hasDecl(Impl, "readMemoryStats")) {
                return Impl.readMemoryStats(out);
            }
            out.* = .{};
            return error.Unsupported;
        }

        pub fn readTaskStats(out: *system.TaskStats) system.StatsError!void {
            if (comptime @hasDecl(Impl, "readTaskStats")) {
                return Impl.readTaskStats(out);
            }
            out.* = .{};
            return error.Unsupported;
        }

        pub const TaskRuntimeEntry = if (@hasDecl(Impl, "TaskRuntimeEntry"))
            Impl.TaskRuntimeEntry
        else
            extern struct {
                name: [16]u8,
                runtime: u64,
            };

        pub fn taskRuntimeSnapshot(entries: []TaskRuntimeEntry) usize {
            if (comptime @hasDecl(Impl, "taskRuntimeSnapshot")) {
                return Impl.taskRuntimeSnapshot(entries);
            } else {
                return 0;
            }
        }
    };
}

pub const test_runner = struct {
    pub const unit = @import("system/test_runner/unit.zig");
};
