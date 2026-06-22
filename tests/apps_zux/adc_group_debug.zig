pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/adc-group-debug",
    .filter = "apps/integration/zux/adc-group-debug",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("zux_adc-group-debug");

test "apps/integration/zux/adc-group-debug" {
    _ = @import("../utils/thirdparty_lvgl_osal.zig");

    const gstd = @import("gstd");

    const TestContext = struct {
        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try app.run(TestContext, gstd.runtime);
}
