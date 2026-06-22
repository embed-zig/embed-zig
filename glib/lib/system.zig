//! system — runtime/system information contract.

const cpu_mod = @import("system/cpu.zig");

pub const cpu = cpu_mod;
pub const CpuCountError = cpu_mod.CpuCountError;

pub fn make(comptime Impl: type) type {
    const RuntimeCpu = cpu_mod.make(Impl);

    return struct {
        pub const CpuCountError = cpu_mod.CpuCountError;
        pub const cpu = RuntimeCpu;

        pub fn cpuCount() cpu_mod.CpuCountError!usize {
            return RuntimeCpu.cpuCount();
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
