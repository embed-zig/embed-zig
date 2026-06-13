pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/preferences-smoke",
    .filter = "apps/integration/zux/preferences-smoke",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("zux_preferences-smoke");

test "apps/integration/zux/preferences-smoke" {
    const gstd = @import("gstd");
    try app.run(app.TestPlatformCtx, gstd.runtime);
}
