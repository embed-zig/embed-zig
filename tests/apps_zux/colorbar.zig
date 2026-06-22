pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/colorbar",
    .filter = "apps/integration/zux/colorbar",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("zux_colorbar");

test "apps/integration/zux/colorbar" {
    _ = @import("../utils/thirdparty_lvgl_osal.zig");

    const gstd = @import("gstd");

    const TestContext = struct {
        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try app.run(TestContext, gstd.runtime);
}
