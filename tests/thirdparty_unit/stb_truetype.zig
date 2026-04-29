pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/stb_truetype",
    .filter = "thirdparty/stb_truetype/unit",
    .label = .unit,
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
