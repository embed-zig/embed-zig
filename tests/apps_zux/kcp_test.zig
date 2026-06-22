pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/kcp-test",
    .filter = "apps/integration/zux/kcp-test",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("zux_kcp-test");

test "apps/integration/zux/kcp-test" {
    const gstd = @import("gstd");

    const TestContext = struct {
        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try app.run(TestContext, gstd.runtime);
}
