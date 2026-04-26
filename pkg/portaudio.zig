//! portaudio — PortAudio bindings and host-audio wrappers.
//!
//! Usage:
//!   const portaudio = @import("portaudio");

const glib = @import("glib");
const gstd = @import("gstd");
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
    pub const unit = @import("portaudio/test_runner/unit.zig");
    pub const integration = @import("portaudio/test_runner/integration.zig");
};

test "portaudio/unit/imports" {
    _ = @import("portaudio/src/binding.zig");
    _ = @import("portaudio/src/types.zig");
    _ = @import("portaudio/src/error.zig");
    _ = @import("portaudio/src/HostApi.zig");
    _ = @import("portaudio/src/Device.zig");
    _ = @import("portaudio/src/StreamParameters.zig");
    _ = @import("portaudio/src/Stream.zig");
    _ = @import("portaudio/src/PortAudio.zig");
}

test "portaudio/unit/root_surface_exposes_foundational_types" {
    const std = @import("std");

    try std.testing.expect(@sizeOf(DeviceIndex) > 0);
    try std.testing.expect(@sizeOf(HostApiIndex) > 0);
    try std.testing.expectEqual(@intFromEnum(SampleFormat.int16), @as(c_ulong, 0x00000008));
    try std.testing.expect(@sizeOf(PortAudio) > 0);
}

test "portaudio/unit/std" {
    var t = glib.testing.T.new(gstd.runtime.std, .portaudio_unit_std);
    defer t.deinit();

    t.run("portaudio", test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "portaudio/unit/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .portaudio_unit_embed_std);
    defer t.deinit();

    t.run("portaudio", test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "portaudio/integration/std" {
    var t = glib.testing.T.new(gstd.runtime.std, .portaudio_integration_std);
    defer t.deinit();

    t.run("portaudio", test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "portaudio/integration/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .portaudio_integration_embed_std);
    defer t.deinit();

    t.run("portaudio", test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
