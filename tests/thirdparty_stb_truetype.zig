pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/stb_truetype",
    .labels = &.{ "integration", "unit" },
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const stb_truetype = @import("stb_truetype");

test "thirdparty/stb_truetype/unit" {
    _ = stb_truetype.FontInfo;
    _ = stb_truetype.Font;
}

test "thirdparty/stb_truetype/integration/embed" {
    var t = glib.testing.T.new(gstd.runtime.std, .stb_truetype_integration_embed);
    defer t.deinit();
    t.run("stb_truetype", stb_truetype.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/stb_truetype/integration/std" {
    var t = glib.testing.T.new(gstd.runtime.std, .stb_truetype_integration_std);
    defer t.deinit();
    t.run("stb_truetype", stb_truetype.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
