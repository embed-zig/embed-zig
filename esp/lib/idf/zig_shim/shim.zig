// Aggregates target-specific Zig shims that are linked as a helper archive.
// Add new shim files here as more runtime gaps are identified.
comptime {
    _ = @import("compiler_rt_ti.zig");
    _ = @import("compiler_rt_tf.zig");
}

test {
    _ = @import("compiler_rt_ti.zig");
    _ = @import("compiler_rt_tf.zig");
}
