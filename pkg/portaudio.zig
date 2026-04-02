//! portaudio — PortAudio bindings and host-audio wrappers.
//!
//! Usage:
//!   const portaudio = @import("portaudio");

const build_options = @import("build_options");
const types = @import("portaudio/src/types.zig");
const error_mod = @import("portaudio/src/error.zig");

pub const PortAudio = @import("portaudio/src/PortAudio.zig");
pub const HostApi = @import("portaudio/src/HostApi.zig");
pub const Device = @import("portaudio/src/Device.zig");
pub const Stream = @import("portaudio/src/Stream.zig");
pub const StreamParameters = @import("portaudio/src/StreamParameters.zig");
pub const DeviceIndex = types.DeviceIndex;
pub const HostApiIndex = types.HostApiIndex;
pub const Time = types.Time;
pub const SampleFormat = types.SampleFormat;
pub const StreamFlags = types.StreamFlags;

pub const Error = error_mod.Error;
pub const ErrorCode = error_mod.ErrorCode;
pub const fromPaError = error_mod.fromPaError;
pub const toError = error_mod.toError;
pub const checkError = error_mod.check;
pub const toErrorText = error_mod.toErrorText;
pub const isOverflow = error_mod.isOverflow;
pub const isUnderflow = error_mod.isUnderflow;

pub const test_runner = struct {
    pub const portaudio = @import("portaudio/test_runner/portaudio.zig");
};

test "portaudio/unit_tests" {
    _ = @import("portaudio/src/binding.zig");
    _ = @import("portaudio/src/types.zig");
    _ = @import("portaudio/src/error.zig");
    _ = @import("portaudio/src/HostApi.zig");
    _ = @import("portaudio/src/Device.zig");
    _ = @import("portaudio/src/StreamParameters.zig");
    _ = @import("portaudio/src/Stream.zig");
    _ = @import("portaudio/src/PortAudio.zig");
}

test "portaudio/unit_tests/root_surface_exposes_foundational_types" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expect(@sizeOf(DeviceIndex) > 0);
    try testing.expect(@sizeOf(HostApiIndex) > 0);
    try testing.expectEqual(@intFromEnum(SampleFormat.int16), @as(c_ulong, 0x00000008));
    try testing.expect(@sizeOf(PortAudio) > 0);
}

test "portaudio/integration_tests/embed" {
    if (!build_options.portaudio_live) return;
    const lib = @import("embed_std").std;
    const testing = @import("testing");

    var t = testing.T.new(lib, .portaudio_integration_embed);
    defer t.deinit();

    t.run("portaudio", test_runner.portaudio.make(lib));
    if (!t.wait()) return error.TestFailed;
}

test "portaudio/integration_tests/std" {
    if (!build_options.portaudio_live) return;
    const lib = @import("std");
    const testing = @import("testing");

    var t = testing.T.new(lib, .portaudio_integration_std);
    defer t.deinit();

    t.run("portaudio", test_runner.portaudio.make(lib));
    if (!t.wait()) return error.TestFailed;
}
