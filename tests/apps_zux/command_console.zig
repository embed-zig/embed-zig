pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/command-console",
    .filter = "apps/integration/zux/command-console",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("zux_command-console");

test "apps/integration/zux/command-console" {
    const gstd = @import("gstd");

    const TestContext = struct {
        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try app.run(TestContext, gstd.runtime);
}
