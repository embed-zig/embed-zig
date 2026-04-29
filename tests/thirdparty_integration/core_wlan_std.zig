pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/core_wlan",
    .filter = "thirdparty/core_wlan/integration/std",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const core_wlan = @import("core_wlan");

test "thirdparty/core_wlan/integration/std" {
    @import("std").testing.log_level = .info;
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .core_wlan_integration_std);
    defer t.deinit();
    t.run("integration", core_wlan.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
