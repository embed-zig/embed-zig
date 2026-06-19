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
    };
}

pub const test_runner = struct {
    pub const unit = @import("system/test_runner/unit.zig");
};
