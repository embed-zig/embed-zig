pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/net-smoke",
    .filter = "apps/integration/zux/net-smoke",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("zux_net-smoke");

test "apps/integration/zux/net-smoke" {
    const gstd = @import("gstd");

    try app.run(app.TestPlatformCtx, gstd.runtime);
}
