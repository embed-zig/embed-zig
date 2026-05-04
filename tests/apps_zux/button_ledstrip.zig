pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/button-ledstrip",
    .filter = "apps/integration/zux/button-ledstrip",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("zux_button-ledstrip");

test "apps/integration/zux/button-ledstrip" {
    const gstd = @import("gstd");

    const TestContext = struct {
        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try app.run(TestContext, gstd.runtime);
}
