pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/speexdsp",
    .filter = "thirdparty/speexdsp/integration/std",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const speexdsp = @import("speexdsp");

test "thirdparty/speexdsp/integration/std" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .speexdsp_integration_std);
    defer t.deinit();
    t.run("integration", speexdsp.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
