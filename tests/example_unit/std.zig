pub const meta = .{
    .source_file = sourceFile(),
    .module = "example/std",
    .filter = "example/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("unit-test_std");

test "example/unit/std" {
    const std = @import("std");
    const gstd = @import("gstd");

    std.testing.log_level = .info;

    const TestContext = struct {
        pub const allocator = std.testing.allocator;

        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try app.run(TestContext, gstd.runtime);
}
