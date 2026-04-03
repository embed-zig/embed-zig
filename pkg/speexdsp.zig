//! speexdsp — SpeexDSP bindings and typed DSP wrappers.
//!
//! Usage:
//!   const speexdsp = @import("speexdsp");
//!   var echo = try speexdsp.EchoState.init(160, 1600);
//!   defer echo.deinit();
//!   var preprocess = try speexdsp.PreprocessState.init(160, 16_000);
//!   defer preprocess.deinit();
//!   try preprocess.setEchoState(&echo);
//!   var resampler = try speexdsp.Resampler.init(1, 16_000, 8_000, speexdsp.resampler_quality_default);
//!   defer resampler.deinit();
//!
//! Stateful wrappers own the underlying C pointer and should have one clear
//! owner. Do not call hot-path process methods concurrently with `deinit()`.
//! Linked preprocess/echo state is borrowed rather than retained, so keep frame
//! sizing and sampling-rate configuration aligned and clear the link before
//! tearing the echo down if the preprocess state will continue to run.

const types = @import("speexdsp/src/types.zig");
const error_mod = @import("speexdsp/src/error.zig");

pub const Sample = types.Sample;
pub const SampleRate = types.SampleRate;
pub const ChannelCount = types.ChannelCount;
pub const Quality = types.Quality;
pub const ProcessResult = types.ProcessResult;
pub const InterleavedProcessResult = types.InterleavedProcessResult;

pub const resampler_quality_min = types.resampler_quality_min;
pub const resampler_quality_max = types.resampler_quality_max;
pub const resampler_quality_default = types.resampler_quality_default;
pub const resampler_quality_voip = types.resampler_quality_voip;
pub const resampler_quality_desktop = types.resampler_quality_desktop;

pub const InitError = error_mod.InitError;
pub const ControlError = error_mod.ControlError;
pub const ResamplerError = error_mod.ResamplerError;
pub const ResamplerErrorCode = error_mod.ResamplerErrorCode;
pub const fromResamplerStatus = error_mod.fromResamplerStatus;
pub const toResamplerErrorCode = error_mod.toResamplerErrorCode;
pub const resamplerErrorText = error_mod.resamplerErrorText;

pub const EchoState = @import("speexdsp/src/EchoState.zig");
pub const PreprocessState = @import("speexdsp/src/PreprocessState.zig");
pub const Resampler = @import("speexdsp/src/Resampler.zig");

pub const test_runner = struct {
    pub const speexdsp = @import("speexdsp/test_runner/speexdsp.zig");
};

test "speexdsp/unit_tests" {
    _ = @import("speexdsp/src/binding.zig");
    _ = @import("speexdsp/src/types.zig");
    _ = @import("speexdsp/src/error.zig");
    _ = @import("speexdsp/src/EchoState.zig");
    _ = @import("speexdsp/src/PreprocessState.zig");
    _ = @import("speexdsp/src/Resampler.zig");
}

test "speexdsp/unit_tests/root_surface_exposes_phase1_wrappers" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expect(@sizeOf(Sample) == 2);
    try testing.expect(resampler_quality_min <= resampler_quality_default);
    try testing.expect(resampler_quality_default <= resampler_quality_max);
}

test "speexdsp/integration_tests/embed" {
    const lib = @import("embed_std").std;
    const testing = @import("testing");

    var t = testing.T.new(lib, .speexdsp_integration_embed);
    defer t.deinit();

    t.run("speexdsp", test_runner.speexdsp.make(lib));
    if (!t.wait()) return error.TestFailed;
}

test "speexdsp/integration_tests/std" {
    const lib = @import("std");
    const testing = @import("testing");

    var t = testing.T.new(lib, .speexdsp_integration_std);
    defer t.deinit();

    t.run("speexdsp", test_runner.speexdsp.make(lib));
    if (!t.wait()) return error.TestFailed;
}
