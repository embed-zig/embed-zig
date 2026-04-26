//! audio.mixer.Format — PCM sample format metadata.

const Format = @This();

rate: u32,
channels: Channels = .mono,

pub const Channels = enum(u2) {
    mono = 1,
    stereo = 2,
};

pub fn channelCount(self: Format) u32 {
    return @intFromEnum(self.channels);
}

pub fn sampleBytes(self: Format) usize {
    return @as(usize, @intFromEnum(self.channels)) * @sizeOf(i16);
}

pub fn eql(a: Format, b: Format) bool {
    return a.rate == b.rate and a.channels == b.channels;
}
