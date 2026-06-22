const bk = @import("../../bk.zig");

pub const Type = bk.embed.audio_adapter.OnboardSpeakerSystem.make(.{
    .sample_rate = 16_000,
    .frame_samples_per_channel = 320,
    .channels = 1,
    .mic_channels = 2,
    .speaker_channels = 1,
    .bits_per_sample = 16,
    .default_volume = 0x2d,
    .default_mic_gain = 0x2a,
    .frame_count = 4,
    .aec = .{},
});
