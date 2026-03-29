const binding = @import("binding.zig");

pub const Error = error{
    BadArg,
    BufferTooSmall,
    InternalError,
    InvalidPacket,
    Unimplemented,
    InvalidState,
    AllocFail,
    Unknown,
};

pub const Application = enum(c_int) {
    voip = binding.OPUS_APPLICATION_VOIP,
    audio = binding.OPUS_APPLICATION_AUDIO,
    restricted_lowdelay = binding.OPUS_APPLICATION_RESTRICTED_LOWDELAY,
};

pub const Signal = enum(c_int) {
    auto = binding.OPUS_AUTO,
    voice = binding.OPUS_SIGNAL_VOICE,
    music = binding.OPUS_SIGNAL_MUSIC,
};

pub const Bandwidth = enum(c_int) {
    auto = binding.OPUS_AUTO,
    narrowband = binding.OPUS_BANDWIDTH_NARROWBAND,
    mediumband = binding.OPUS_BANDWIDTH_MEDIUMBAND,
    wideband = binding.OPUS_BANDWIDTH_WIDEBAND,
    superwideband = binding.OPUS_BANDWIDTH_SUPERWIDEBAND,
    fullband = binding.OPUS_BANDWIDTH_FULLBAND,
};

test "opus/unit_tests/types/enum_values_match_opus_bindings" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expectEqual(@as(c_int, binding.OPUS_APPLICATION_VOIP), @intFromEnum(Application.voip));
    try testing.expectEqual(@as(c_int, binding.OPUS_APPLICATION_AUDIO), @intFromEnum(Application.audio));
    try testing.expectEqual(@as(c_int, binding.OPUS_APPLICATION_RESTRICTED_LOWDELAY), @intFromEnum(Application.restricted_lowdelay));

    try testing.expectEqual(@as(c_int, binding.OPUS_AUTO), @intFromEnum(Signal.auto));
    try testing.expectEqual(@as(c_int, binding.OPUS_SIGNAL_VOICE), @intFromEnum(Signal.voice));
    try testing.expectEqual(@as(c_int, binding.OPUS_SIGNAL_MUSIC), @intFromEnum(Signal.music));

    try testing.expectEqual(@as(c_int, binding.OPUS_AUTO), @intFromEnum(Bandwidth.auto));
    try testing.expectEqual(@as(c_int, binding.OPUS_BANDWIDTH_NARROWBAND), @intFromEnum(Bandwidth.narrowband));
    try testing.expectEqual(@as(c_int, binding.OPUS_BANDWIDTH_MEDIUMBAND), @intFromEnum(Bandwidth.mediumband));
    try testing.expectEqual(@as(c_int, binding.OPUS_BANDWIDTH_WIDEBAND), @intFromEnum(Bandwidth.wideband));
    try testing.expectEqual(@as(c_int, binding.OPUS_BANDWIDTH_SUPERWIDEBAND), @intFromEnum(Bandwidth.superwideband));
    try testing.expectEqual(@as(c_int, binding.OPUS_BANDWIDTH_FULLBAND), @intFromEnum(Bandwidth.fullband));
}
