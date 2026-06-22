pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/chant",
    .filter = "apps/integration/zux/chant",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const app = @import("zux_chant_touch");
const app_adc = @import("zux_chant_adc");

test "apps/integration/zux/chant/virtual" {
    _ = @import("../utils/thirdparty_lvgl_osal.zig");

    const gstd = @import("gstd");

    const TestContext = struct {
        pub const AudioSystem = app.TestPlatformCtx.AudioSystem;

        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try app.run(TestContext, gstd.runtime);
}

test "apps/integration/zux/chant/adc" {
    _ = @import("../utils/thirdparty_lvgl_osal.zig");

    const gstd = @import("gstd");

    const TestContext = struct {
        pub const AudioSystem = app_adc.TestPlatformCtx.AudioSystem;

        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try app_adc.run(TestContext, gstd.runtime);
}
