pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/portaudio",
    .labels = &.{ "integration", "unit" },
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

test "thirdparty/portaudio/unit/root_surface_exposes_foundational_types" {
    const std = @import("std");
    try std.testing.expect(@sizeOf(portaudio.DeviceIndex) > 0);
    try std.testing.expect(@sizeOf(portaudio.HostApiIndex) > 0);
    try std.testing.expectEqual(@intFromEnum(portaudio.SampleFormat.int16), @as(c_ulong, 0x00000008));
    try std.testing.expect(@sizeOf(portaudio.PortAudio) > 0);
}

test "thirdparty/portaudio/unit/std" {
    var t = glib.testing.T.new(gstd.runtime.std, .portaudio_unit_std);
    defer t.deinit();
    t.run("portaudio", portaudio.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/portaudio/unit/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .portaudio_unit_embed_std);
    defer t.deinit();
    t.run("portaudio", portaudio.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/portaudio/integration/std" {
    var t = glib.testing.T.new(gstd.runtime.std, .portaudio_integration_std);
    defer t.deinit();
    t.run("portaudio", portaudio.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/portaudio/integration/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .portaudio_integration_embed_std);
    defer t.deinit();
    t.run("portaudio", portaudio.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
