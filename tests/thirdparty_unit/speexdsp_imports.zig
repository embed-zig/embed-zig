pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/speexdsp",
    .filter = "thirdparty/speexdsp/unit/imports",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const speexdsp = @import("speexdsp");

test "thirdparty/speexdsp/unit/imports" {
    _ = speexdsp.EchoState;
    _ = speexdsp.PreprocessState;
    _ = speexdsp.Resampler;
}
