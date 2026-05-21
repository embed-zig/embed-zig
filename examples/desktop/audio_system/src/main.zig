const std = @import("std");
const desktop_audio_system = @import("desktop_audio_system");
const config = @import("audio_system_example_config");

const AudioSystem = desktop_audio_system.AudioSystem;
const sample_rate: u32 = 16_000;
const frame_samples: usize = 320;
const frame_duration_ms: u32 = 20;
const tau: f32 = 6.283185307179586;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var system = try AudioSystem.init(allocator);
    defer system.deinit();

    try system.setSpkGain(config.gain_db);
    const rate = try system.spkSampleRate();
    std.log.info("desktop audio system: rate={d}Hz duration={d}ms gain={d}dB loopback_gain={d}dB music={}", .{
        rate,
        config.duration_ms,
        config.gain_db,
        config.loopback_gain_db,
        config.music,
    });

    var high_track = try system.createTrack(.{
        .label = "czerny-high",
        .gain = 0.78,
        .buffer_capacity = frame_samples * 32,
    });
    defer high_track.track.deinit();
    defer high_track.ctrl.deinit();

    var low_track = try system.createTrack(.{
        .label = "czerny-low",
        .gain = 0.58,
        .buffer_capacity = frame_samples * 32,
    });
    defer low_track.track.deinit();
    defer low_track.ctrl.deinit();

    var loopback_track = try system.createTrack(.{
        .label = "mic-loopback",
        .gain = 1.0,
        .buffer_capacity = frame_samples * 64,
    });
    defer loopback_track.track.deinit();
    defer loopback_track.ctrl.deinit();

    try system.start();
    defer system.stop() catch {};

    var loopback = LoopbackThread{
        .system = &system,
        .track = loopback_track.track,
        .gain_db = config.loopback_gain_db,
    };
    const mic_thread = try std.Thread.spawn(.{}, LoopbackThread.run, .{&loopback});
    defer {
        loopback.running.store(false, .release);
        loopback_track.ctrl.closeWrite();
        mic_thread.join();
    }

    const total_frames = @max(@as(u32, 1), config.duration_ms / frame_duration_ms);
    var high_voice = Voice.init(high_phrase[0..], 7600);
    var low_voice = Voice.init(low_phrase[0..], 5600);
    var high_frame: [frame_samples]i16 = undefined;
    var low_frame: [frame_samples]i16 = undefined;

    for (0..total_frames) |_| {
        high_voice.render(high_frame[0..], rate);
        low_voice.render(low_frame[0..], rate);

        if (config.music) {
            try high_track.track.write(.{ .rate = rate, .channels = .mono }, high_frame[0..]);
            try low_track.track.write(.{ .rate = rate, .channels = .mono }, low_frame[0..]);
        }

        std.Thread.sleep(frame_duration_ms * std.time.ns_per_ms);
    }

    high_track.ctrl.closeWrite();
    low_track.ctrl.closeWrite();
    std.Thread.sleep(200 * std.time.ns_per_ms);

    std.log.info(
        "desktop audio system done: high_bytes={d} low_bytes={d} mic_reads={d} loopback_writes={d} mic_peak={d} loopback_peak={d}",
        .{
            high_track.ctrl.readBytes(),
            low_track.ctrl.readBytes(),
            loopback.reads,
            loopback.writes,
            loopback.input_peak,
            loopback.output_peak,
        },
    );
}

const LoopbackThread = struct {
    system: *AudioSystem,
    track: AudioSystem.Track,
    gain_db: i8,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    reads: usize = 0,
    writes: usize = 0,
    input_peak: u16 = 0,
    output_peak: u16 = 0,

    fn run(self: *LoopbackThread) void {
        var frame: [frame_samples]i16 = undefined;

        while (self.running.load(.acquire)) {
            const n = self.system.read(frame[0..]) catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(2 * std.time.ns_per_ms);
                    continue;
                },
                error.InvalidState => break,
                else => {
                    std.log.warn("mic loopback read failed: {s}", .{@errorName(err)});
                    break;
                },
            };
            if (n == 0) continue;

            self.reads += 1;
            self.input_peak = @max(self.input_peak, peakAbs(frame[0..n]));
            applyGain(frame[0..n], self.gain_db);
            self.output_peak = @max(self.output_peak, peakAbs(frame[0..n]));
            self.track.write(.{ .rate = sample_rate, .channels = .mono }, frame[0..n]) catch |err| {
                if (self.running.load(.acquire)) {
                    std.log.warn("mic loopback write failed: {s}", .{@errorName(err)});
                }
                break;
            };
            self.writes += 1;
        }
    }
};

const Note = struct {
    midi: u8,
    frames: u8,
};

const Voice = struct {
    phrase: []const Note,
    amplitude: i16,
    index: usize = 0,
    frames_left: u32 = 0,
    phase: f32 = 0,

    fn init(phrase: []const Note, amplitude: i16) Voice {
        return .{
            .phrase = phrase,
            .amplitude = amplitude,
            .frames_left = phrase[0].frames,
        };
    }

    fn render(self: *Voice, out: []i16, rate: u32) void {
        const note = self.phrase[self.index];
        const freq = midiToHz(note.midi);
        const step = tau * freq / @as(f32, @floatFromInt(rate));
        const gain = envelope(self.frames_left, note.frames);

        for (out) |*sample| {
            const fundamental = std.math.sin(self.phase);
            const overtone = 0.18 * std.math.sin(self.phase * 2.0);
            const value = (fundamental + overtone) * @as(f32, @floatFromInt(self.amplitude)) * gain;
            sample.* = clampSample(value);
            self.phase += step;
            if (self.phase >= tau) self.phase -= tau;
        }

        if (self.frames_left > 1) {
            self.frames_left -= 1;
            return;
        }

        self.index = (self.index + 1) % self.phrase.len;
        self.frames_left = self.phrase[self.index].frames;
    }
};

const high_phrase = [_]Note{
    .{ .midi = 72, .frames = 6 },
    .{ .midi = 76, .frames = 6 },
    .{ .midi = 79, .frames = 6 },
    .{ .midi = 84, .frames = 6 },
    .{ .midi = 83, .frames = 6 },
    .{ .midi = 79, .frames = 6 },
    .{ .midi = 76, .frames = 6 },
    .{ .midi = 72, .frames = 6 },
    .{ .midi = 74, .frames = 6 },
    .{ .midi = 77, .frames = 6 },
    .{ .midi = 81, .frames = 6 },
    .{ .midi = 86, .frames = 6 },
    .{ .midi = 84, .frames = 6 },
    .{ .midi = 81, .frames = 6 },
    .{ .midi = 77, .frames = 6 },
    .{ .midi = 74, .frames = 6 },
    .{ .midi = 71, .frames = 6 },
    .{ .midi = 74, .frames = 6 },
    .{ .midi = 77, .frames = 6 },
    .{ .midi = 83, .frames = 6 },
    .{ .midi = 81, .frames = 6 },
    .{ .midi = 77, .frames = 6 },
    .{ .midi = 74, .frames = 6 },
    .{ .midi = 71, .frames = 6 },
    .{ .midi = 72, .frames = 12 },
    .{ .midi = 79, .frames = 12 },
    .{ .midi = 84, .frames = 12 },
    .{ .midi = 79, .frames = 12 },
};

const low_phrase = [_]Note{
    .{ .midi = 48, .frames = 12 },
    .{ .midi = 55, .frames = 12 },
    .{ .midi = 60, .frames = 12 },
    .{ .midi = 55, .frames = 12 },
    .{ .midi = 50, .frames = 12 },
    .{ .midi = 57, .frames = 12 },
    .{ .midi = 62, .frames = 12 },
    .{ .midi = 57, .frames = 12 },
    .{ .midi = 47, .frames = 12 },
    .{ .midi = 55, .frames = 12 },
    .{ .midi = 59, .frames = 12 },
    .{ .midi = 55, .frames = 12 },
    .{ .midi = 48, .frames = 24 },
    .{ .midi = 55, .frames = 24 },
};

fn midiToHz(midi: u8) f32 {
    const semitone = (@as(f32, @floatFromInt(midi)) - 69.0) / 12.0;
    return 440.0 * std.math.pow(f32, 2.0, semitone);
}

fn envelope(frames_left: u32, total_frames: u8) f32 {
    if (total_frames <= 1) return 1.0;
    if (frames_left == total_frames) return 0.55;
    if (frames_left == 1) return 0.72;
    return 1.0;
}

fn peakAbs(samples: []const i16) u16 {
    var peak: u16 = 0;
    for (samples) |sample| {
        const abs = if (sample == std.math.minInt(i16)) std.math.maxInt(i16) else @abs(sample);
        peak = @max(peak, abs);
    }
    return peak;
}

fn applyGain(samples: []i16, gain_db: i8) void {
    const gain = gainLinear(gain_db);
    for (samples) |*sample| {
        sample.* = clampSample(@as(f32, @floatFromInt(sample.*)) * gain);
    }
}

fn gainLinear(gain_db: i8) f32 {
    if (gain_db == 0) return 1.0;
    return std.math.pow(f32, 10.0, @as(f32, @floatFromInt(gain_db)) / 20.0);
}

fn clampSample(value: f32) i16 {
    if (value > 32767.0) return 32767;
    if (value < -32768.0) return -32768;
    return @intFromFloat(value);
}
