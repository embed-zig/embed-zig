pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/glib/unit-test",
    .filter = "apps/unit/glib/unit-test",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("glib_unit-test");

test "apps/unit/glib/unit-test" {
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
