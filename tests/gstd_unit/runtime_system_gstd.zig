pub const meta = .{
    .source_file = sourceFile(),
    .module = "gstd/runtime",
    .filter = "gstd/runtime/unit/system/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const gstd = @import("gstd");

test "gstd/runtime/unit/system/gstd" {
    const std = @import("std");

    const count = try gstd.runtime.system.cpuCount();
    try std.testing.expect(count > 0);
}
