pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/fs-smoke",
    .filter = "apps/integration/zux/fs-smoke",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("zux_fs-smoke");

test "apps/integration/zux/fs-smoke" {
    const gstd = @import("gstd");

    const TestContext = struct {
        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try app.run(TestContext, gstd.runtime);
}
