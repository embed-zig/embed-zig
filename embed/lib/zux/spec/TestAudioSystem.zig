const audio = @import("audio");
const component_audio_system = @import("../component/audio_system.zig");
const glib = @import("glib");

const TestAudioSystem = @This();

pub const State = struct {
    started: bool = false,
    start_count: usize = 0,
    stop_count: usize = 0,
    created_tracks: usize = 0,
    writes: usize = 0,
    reads: usize = 0,
    discard_read_count: usize = 0,
    sample_rate_requests: usize = 0,
    gain_db: i8 = 0,
    mic_gain_count: u8 = 0,
    mic_gains: [component_audio_system.State.max_mic_gains]?i8 = [_]?i8{null} ** component_audio_system.State.max_mic_gains,
    last_write_rate: u32 = 0,
    last_write_samples: usize = 0,
};

pub const TrackHandle = struct {
    ctrl: TrackCtrl = .{},
    track: Track,
};

pub const TrackCtrl = struct {
    pub fn closeWrite(_: @This()) void {}
    pub fn closeWithError(_: @This()) void {}
    pub fn deinit(_: @This()) void {}
};

pub const Track = struct {
    owner: *TestAudioSystem,

    pub fn write(self: *@This(), format: audio.Mixer.Format, samples: []const i16) !void {
        self.owner.state.writes += 1;
        self.owner.state.last_write_rate = format.rate;
        self.owner.state.last_write_samples = samples.len;
        _ = durationForSamples(samples.len, format.rate);
    }

    pub fn deinit(_: *@This()) void {}
};

state: State = .{},

pub fn reset(self: *TestAudioSystem) void {
    self.state = .{};
}

pub fn start(self: *TestAudioSystem) !void {
    self.state.started = true;
    self.state.start_count += 1;
}

pub fn stop(self: *TestAudioSystem) !void {
    self.state.started = false;
    self.state.stop_count += 1;
}

pub fn createTrack(self: *TestAudioSystem, _: audio.Mixer.Track.Config) !TrackHandle {
    self.state.created_tracks += 1;
    return .{
        .track = .{
            .owner = self,
        },
    };
}

pub fn read(self: *TestAudioSystem, out: []i16) !usize {
    self.state.reads += 1;
    const n = @min(out.len, 16);
    for (out[0..n]) |*sample| sample.* = 0;
    return n;
}

pub fn discardReadBuffer(self: *TestAudioSystem) void {
    self.state.discard_read_count += 1;
}

pub fn setSpkGain(self: *TestAudioSystem, gain_db: i8) !void {
    self.state.gain_db = gain_db;
}

pub fn setMicGains(self: *TestAudioSystem, gains_db: []const ?i8) !void {
    self.state.mic_gain_count = @intCast(@min(gains_db.len, component_audio_system.State.max_mic_gains));
    for (0..self.state.mic_gain_count) |i| {
        self.state.mic_gains[i] = gains_db[i];
    }
}

pub fn spkSampleRate(self: *TestAudioSystem) !u32 {
    self.state.sample_rate_requests += 1;
    return 16_000;
}

fn durationForSamples(sample_count: usize, sample_rate: u32) glib.time.duration.Duration {
    if (sample_count == 0 or sample_rate == 0) return 0;

    const duration_128 = (@as(u128, @intCast(sample_count)) * @as(u128, @intCast(glib.time.duration.Second))) /
        @as(u128, sample_rate);
    return @intCast(@min(duration_128, @as(u128, @intCast(glib.time.duration.Maximum))));
}
