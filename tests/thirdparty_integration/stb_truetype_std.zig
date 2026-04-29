pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/stb_truetype",
    .filter = "thirdparty/stb_truetype/integration/std",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const stb_truetype = @import("stb_truetype");

test "thirdparty/stb_truetype/integration/std" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .stb_truetype_integration_std);
    defer t.deinit();
    t.run("stb_truetype", stb_truetype.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
