//! Host-backed system information implementations.

const std = @import("std");
const glib = @import("glib");

pub const impl = struct {
    pub fn cpuCount() glib.system.CpuCountError!usize {
        return try std.Thread.getCpuCount();
    }
};
