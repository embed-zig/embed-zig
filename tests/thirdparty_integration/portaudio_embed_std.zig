pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/portaudio",
    .filter = "thirdparty/portaudio/integration/embed_std",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const portaudio = @import("portaudio");

test "thirdparty/portaudio/integration/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .portaudio_integration_embed_std);
    defer t.deinit();
    t.run("portaudio", portaudio.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
