pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/core_wlan",
    .filter = "thirdparty/core_wlan/unit/embed_std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const core_wlan = @import("core_wlan");

test "thirdparty/core_wlan/unit/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .core_wlan_unit_embed_std);
    defer t.deinit();
    t.run("unit", core_wlan.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
