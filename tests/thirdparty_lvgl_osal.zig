const std = @import("std");
const gstd = @import("gstd");
const lvgl_osal = @import("lvgl_osal");

comptime {
    _ = lvgl_osal.make(gstd.runtime, std.heap.page_allocator);
}
