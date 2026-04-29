pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/portaudio",
    .filter = "thirdparty/portaudio/unit/embed_std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const portaudio = @import("portaudio");

test "thirdparty/portaudio/unit/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .portaudio_unit_embed_std);
    defer t.deinit();
    t.run("portaudio", portaudio.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
