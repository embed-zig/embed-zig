const binding = @import("binding.zig");

pub const Sample = binding.spx_int16_t;
pub const SampleRate = u32;
pub const ChannelCount = u32;
pub const Quality = c_int;

pub const resampler_quality_min: Quality = binding.SPEEX_RESAMPLER_QUALITY_MIN;
pub const resampler_quality_max: Quality = binding.SPEEX_RESAMPLER_QUALITY_MAX;
pub const resampler_quality_default: Quality = binding.SPEEX_RESAMPLER_QUALITY_DEFAULT;
pub const resampler_quality_voip: Quality = binding.SPEEX_RESAMPLER_QUALITY_VOIP;
pub const resampler_quality_desktop: Quality = binding.SPEEX_RESAMPLER_QUALITY_DESKTOP;

pub const ProcessResult = struct {
    input_consumed: usize,
    output_produced: usize,
};

pub const InterleavedProcessResult = struct {
    input_frames_consumed: usize,
    output_frames_produced: usize,
};

test "speexdsp/unit_tests/types/exposes_expected_audio_primitives" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 2), @sizeOf(Sample));
    try testing.expect(resampler_quality_min <= resampler_quality_default);
    try testing.expect(resampler_quality_default <= resampler_quality_max);
}
