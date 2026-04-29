pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/portaudio",
    .filter = "thirdparty/portaudio/unit/root_surface_exposes_foundational_types",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const portaudio = @import("portaudio");

test "thirdparty/portaudio/unit/root_surface_exposes_foundational_types" {
    const std = @import("std");
    try std.testing.expect(@sizeOf(portaudio.DeviceIndex) > 0);
    try std.testing.expect(@sizeOf(portaudio.HostApiIndex) > 0);
    try std.testing.expectEqual(@intFromEnum(portaudio.SampleFormat.int16), @as(c_ulong, 0x00000008));
    try std.testing.expect(@sizeOf(portaudio.PortAudio) > 0);
}
