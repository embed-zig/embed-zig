pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/lvgl",
    .filter = "thirdparty/lvgl/integration",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const lvgl = @import("lvgl");

test "thirdparty/lvgl/integration" {
    _ = @import("../utils/thirdparty_lvgl_osal.zig");

    const std = @import("std");
    std.testing.log_level = .info;
    var t = glib.testing.T.new(std, gstd.runtime.time, .lvgl_integration);
    defer t.deinit();
    var testing_display = lvgl.IntegrationTestingDisplay.initPassthrough(std.testing.allocator, 320, 240, null);
    defer testing_display.deinit();
    var harness_display = try testing_display.display(gstd.runtime);
    defer harness_display.deinit();
    t.run("integration", lvgl.test_runner.integration.make(gstd.runtime, &harness_display));
    if (!t.wait()) return error.TestFailed;
    try testing_display.assertComplete();
}
