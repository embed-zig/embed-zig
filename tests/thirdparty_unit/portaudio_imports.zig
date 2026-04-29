pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/portaudio",
    .filter = "thirdparty/portaudio/unit/imports",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const portaudio = @import("portaudio");

test "thirdparty/portaudio/unit/imports" {
    _ = portaudio.PortAudio;
    _ = portaudio.HostApi;
    _ = portaudio.Device;
    _ = portaudio.StreamParameters;
    _ = portaudio.Stream;
}
