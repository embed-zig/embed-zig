pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/system-smoke",
    .filter = "apps/integration/zux/system-smoke",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("zux_system-smoke");

test "apps/integration/zux/system-smoke" {
    const gstd = @import("gstd");

    const TestContext = struct {
        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try app.run(TestContext, gstd.runtime);
}
