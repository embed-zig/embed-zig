pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/compress-smoke",
    .filter = "apps/integration/zux/compress-smoke",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("zux_compress-smoke");

test "apps/integration/zux/compress-smoke" {
    const gstd = @import("gstd");

    const TestContext = struct {
        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try app.run(TestContext, gstd.runtime);
}
