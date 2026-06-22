const glib = @import("glib");

pub fn cpuCount() glib.system.CpuCountError!usize {
    return 1;
}
