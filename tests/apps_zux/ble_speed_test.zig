pub const meta = .{
    .source_file = sourceFile(),
    .module = "apps/zux/ble-speed-test",
    .filter = "apps/integration/zux/ble-speed-test",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const client_app = @import("zux_ble-speed-test-client");
const server_app = @import("zux_ble-speed-test-server");

test "apps/integration/zux/ble-speed-test/client" {
    _ = @import("../utils/thirdparty_lvgl_osal.zig");

    const gstd = @import("gstd");

    const TestContext = struct {
        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try client_app.run(TestContext, gstd.runtime);
}

test "apps/integration/zux/ble-speed-test/server" {
    _ = @import("../utils/thirdparty_lvgl_osal.zig");

    const gstd = @import("gstd");

    const TestContext = struct {
        pub fn setup() !void {}
        pub fn teardown() void {}
    };

    try server_app.run(TestContext, gstd.runtime);
}
