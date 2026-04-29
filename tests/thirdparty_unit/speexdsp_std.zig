pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/speexdsp",
    .filter = "thirdparty/speexdsp/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const speexdsp = @import("speexdsp");

test "thirdparty/speexdsp/unit/std" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .speexdsp_unit_std);
    defer t.deinit();
    t.run("unit", speexdsp.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
