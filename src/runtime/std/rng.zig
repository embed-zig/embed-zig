const std = @import("std");
const runtime = struct {
    pub const rng = @import("../rng.zig");
};

pub const Rng = struct {
    pub fn fill(_: Rng, buf: []u8) runtime.rng.Error!void {
        std.crypto.random.bytes(buf);
    }
};
