const esp = @import("esp");
const runtime = @import("runtime");

pub const System = struct {
    pub fn getCpuCount(_: System) runtime.system.Error!usize {
        const count = esp.cpu.getCoreCount();
        if (count == 0) return runtime.system.Error.QueryFailed;
        return count;
    }
};
