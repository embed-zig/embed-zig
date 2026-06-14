pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/archive-smoke",
    .filter = "apps/integration/zux/archive-smoke",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("zux_archive-smoke");

test "apps/integration/zux/archive-smoke" {
    const gstd = @import("gstd");

    const TestContext = struct {
        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try app.run(TestContext, gstd.runtime);
}
