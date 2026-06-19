pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/time-smoke",
    .filter = "apps/integration/zux/time-smoke",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("zux_time-smoke");

test "apps/integration/zux/time-smoke" {
    const gstd = @import("gstd");

    const TestContext = struct {
        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try app.run(TestContext, gstd.runtime);
}
