pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/core_bluetooth",
    .labels = &.{ "integration", "unit" },
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const core_bluetooth = @import("core_bluetooth");

test "thirdparty/core_bluetooth/unit/std" {
    var t = glib.testing.T.new(gstd.runtime.std, .core_bluetooth_unit_std);
    defer t.deinit();
    t.run("unit", core_bluetooth.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/core_bluetooth/unit/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .core_bluetooth_unit_embed_std);
    defer t.deinit();
    t.run("unit", core_bluetooth.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/core_bluetooth/integration/std" {
    @import("std").testing.log_level = .info;
    var t = glib.testing.T.new(gstd.runtime.std, .core_bluetooth_integration_std);
    defer t.deinit();
    t.run("integration", core_bluetooth.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/core_bluetooth/integration/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .core_bluetooth_integration_embed_std);
    defer t.deinit();
    t.run("integration", core_bluetooth.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
