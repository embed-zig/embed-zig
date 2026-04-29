pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/core_bluetooth",
    .filter = "thirdparty/core_bluetooth/unit/embed_std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const core_bluetooth = @import("core_bluetooth");

test "thirdparty/core_bluetooth/unit/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .core_bluetooth_unit_embed_std);
    defer t.deinit();
    t.run("unit", core_bluetooth.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
