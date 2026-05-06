const std = @import("std");
const gstd = @import("gstd");
const opus_osal = @import("opus_osal");

comptime {
    _ = opus_osal.make(gstd.runtime, std.heap.page_allocator);
}
