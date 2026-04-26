//! Host-backed time implementations.

pub const instant = @import("time/instant.zig");

pub const impl: type = struct {
    pub const instant: type = @import("time/instant.zig").impl;
};
