const binding = @import("binding.zig");
const types = @import("types.zig");

const Self = @This();

device: types.DeviceIndex,
channel_count: u16,
sample_format: types.SampleFormat,
suggested_latency: f64,
host_api_specific_stream_info: ?*anyopaque = null,

pub fn toC(self: Self) binding.PaStreamParameters {
    return .{
        .device = self.device,
        .channelCount = self.channel_count,
        .sampleFormat = types.toPaSampleFormat(self.sample_format),
        .suggestedLatency = self.suggested_latency,
        .hostApiSpecificStreamInfo = self.host_api_specific_stream_info,
    };
}

pub fn frameSampleCount(self: Self, frames: usize) usize {
    return frames * self.channel_count;
}

test "portaudio/unit_tests/stream_parameters/converts_to_portaudio_struct" {
    const std = @import("std");
    const testing = std.testing;

    const params: Self = .{
        .device = 3,
        .channel_count = 2,
        .sample_format = .int16,
        .suggested_latency = 0.05,
    };
    const c_params = params.toC();

    try testing.expectEqual(@as(types.DeviceIndex, 3), c_params.device);
    try testing.expectEqual(@as(c_int, 2), c_params.channelCount);
    try testing.expectEqual(binding.paInt16, c_params.sampleFormat);
    try testing.expectEqual(@as(f64, 0.05), c_params.suggestedLatency);
    try testing.expectEqual(@as(?*anyopaque, null), c_params.hostApiSpecificStreamInfo);
}

test "portaudio/unit_tests/stream_parameters/frame_sample_count_tracks_channels" {
    const std = @import("std");
    const testing = std.testing;

    const params: Self = .{
        .device = 1,
        .channel_count = 2,
        .sample_format = .int16,
        .suggested_latency = 0.01,
    };

    try testing.expectEqual(@as(usize, 8), params.frameSampleCount(4));
}
