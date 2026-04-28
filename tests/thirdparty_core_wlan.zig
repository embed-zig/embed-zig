pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/core_wlan",
    .labels = &.{ "integration", "unit" },
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const core_wlan = @import("core_wlan");

test "thirdparty/core_wlan/unit/std" {
    var t = glib.testing.T.new(gstd.runtime.std, .core_wlan_unit_std);
    defer t.deinit();
    t.run("unit", core_wlan.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/core_wlan/unit/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .core_wlan_unit_embed_std);
    defer t.deinit();
    t.run("unit", core_wlan.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/core_wlan/integration/std" {
    @import("std").testing.log_level = .info;
    var t = glib.testing.T.new(gstd.runtime.std, .core_wlan_integration_std);
    defer t.deinit();
    t.run("integration", core_wlan.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/core_wlan/integration/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .core_wlan_integration_embed_std);
    defer t.deinit();
    t.run("integration", core_wlan.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
