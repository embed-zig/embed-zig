pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/core_bluetooth",
    .filter = "thirdparty/core_bluetooth/integration/embed_std",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const core_bluetooth = @import("core_bluetooth");

test "thirdparty/core_bluetooth/integration/embed_std" {
    // CoreBluetooth uses the Objective-C runtime, which is not fork-safe once initialized.
    const TestStd = glib.testing.std.make(gstd.runtime.std, .{ .isolate_thread = false });
    var t = glib.testing.T.new(TestStd, gstd.runtime.time, .core_bluetooth_integration_embed_std);
    defer t.deinit();
    t.run("integration", core_bluetooth.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
