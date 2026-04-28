const glib = @import("glib");
const binding = @import("../../../src/binding.zig");
const Encoder = @import("../../../src/Encoder.zig");
const Decoder = @import("../../../src/Decoder.zig");
const Packet = @import("../../../src/Packet.zig");

pub fn makeVersionCheck(comptime grt: type) glib.testing.TestRunner {
    _ = grt;
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const version = binding.getVersionString();
            if (version[0] == 0) {
                t.logFatal("opus version string is empty");
                return false;
            }
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

pub fn makeInt16Scenario(comptime grt: type, sample_rate: u32, channels: u8, seconds: usize) glib.testing.TestRunner {
    const Runner = struct {
        sample_rate: u32,
        channels: u8,
        seconds: usize,

        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = allocator;
            runInt16Scenario(grt, self.sample_rate, self.channels, self.seconds) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            grt.std.testing.allocator.destroy(self);
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{
        .sample_rate = sample_rate,
        .channels = channels,
        .seconds = seconds,
    };
    return glib.testing.TestRunner.make(Runner).new(runner);
}

pub fn makeFloatScenario(comptime grt: type, sample_rate: u32, channels: u8, seconds: usize) glib.testing.TestRunner {
    const Runner = struct {
        sample_rate: u32,
        channels: u8,
        seconds: usize,

        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = allocator;
            runFloatScenario(grt, self.sample_rate, self.channels, self.seconds) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            grt.std.testing.allocator.destroy(self);
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{
        .sample_rate = sample_rate,
        .channels = channels,
        .seconds = seconds,
    };
    return glib.testing.TestRunner.make(Runner).new(runner);
}

fn runInt16Scenario(comptime grt: type, sample_rate: u32, channels: u8, seconds: usize) !void {
    const frame_ms: u32 = 20;
    const frame_size: usize = sample_rate * frame_ms / 1000;
    const frame_count: usize = seconds * 1000 / frame_ms;
    const channel_count: usize = channels;
    const frame_stride: usize = frame_size * channel_count;
    const total_samples = frame_count * frame_stride;

    var encoder = try Encoder.init(grt.std.testing.allocator, sample_rate, channels, .audio);
    defer encoder.deinit(grt.std.testing.allocator);
    var decoder = try Decoder.init(grt.std.testing.allocator, sample_rate, channels);
    defer decoder.deinit(grt.std.testing.allocator);

    try grt.std.testing.expectEqual(@as(u32, @intCast(frame_size)), encoder.frameSizeForMs(frame_ms));
    try grt.std.testing.expectEqual(@as(u32, @intCast(frame_size)), decoder.frameSizeForMs(frame_ms));

    try encoder.setBitrate(128_000);
    try grt.std.testing.expect(try encoder.getBitrate() > 0);
    try encoder.setComplexity(10);
    try encoder.setSignal(.music);
    try encoder.setBandwidth(.fullband);
    try encoder.setVbr(false);
    try encoder.setDtx(false);
    try encoder.resetState();
    try grt.std.testing.expectEqual(sample_rate, try decoder.getSampleRate());

    const original = try grt.std.testing.allocator.alloc(i16, total_samples);
    defer grt.std.testing.allocator.free(original);
    const decoded = try grt.std.testing.allocator.alloc(i16, total_samples);
    defer grt.std.testing.allocator.free(decoded);

    var packet_buf: [1500]u8 = undefined;
    for (0..frame_count) |frame_idx| {
        const offset = frame_idx * frame_stride;
        const sample_offset = frame_idx * frame_size;
        const in_frame = original[offset .. offset + frame_stride];
        const out_frame = decoded[offset .. offset + frame_stride];

        fillMusicFrame(in_frame, sample_offset, sample_rate, channels);

        const packet = try encoder.encode(in_frame, @intCast(frame_size), packet_buf[0..]);
        try grt.std.testing.expect(packet.len > 0);
        try grt.std.testing.expectEqual(channels, try Packet.getChannels(packet));
        try grt.std.testing.expectEqual(@as(u32, 1), try Packet.getFrames(packet));
        try grt.std.testing.expectEqual(@as(u32, @intCast(frame_size)), try Packet.getSamples(packet, sample_rate));

        const samples = try decoder.decode(packet, out_frame, false);
        try grt.std.testing.expectEqual(frame_stride, samples.len);
    }

    const plc_buf = try grt.std.testing.allocator.alloc(i16, frame_stride);
    defer grt.std.testing.allocator.free(plc_buf);
    const concealed = try decoder.plc(plc_buf);
    try grt.std.testing.expectEqual(frame_stride, concealed.len);

    const max_shift: usize = 512;
    const metrics = comparePcmInterleaved(original, decoded, channel_count, max_shift);
    try grt.std.testing.expect(metrics.best_shift <= max_shift);
    try grt.std.testing.expect(metrics.correlation > 0.75);
    try grt.std.testing.expect(metrics.mean_abs_error < 5_000.0);
    try grt.std.testing.expect(metrics.energy_ratio > 0.10);
    try grt.std.testing.expect(metrics.energy_ratio < 2.20);
}

fn runFloatScenario(comptime grt: type, sample_rate: u32, channels: u8, seconds: usize) !void {
    const frame_ms: u32 = 20;
    const frame_size: usize = sample_rate * frame_ms / 1000;
    const frame_count: usize = seconds * 1000 / frame_ms;
    const channel_count: usize = channels;
    const frame_stride: usize = frame_size * channel_count;
    const total_samples = frame_count * frame_stride;

    var encoder = try Encoder.init(grt.std.testing.allocator, sample_rate, channels, .audio);
    defer encoder.deinit(grt.std.testing.allocator);
    var decoder = try Decoder.init(grt.std.testing.allocator, sample_rate, channels);
    defer decoder.deinit(grt.std.testing.allocator);

    const original = try grt.std.testing.allocator.alloc(f32, total_samples);
    defer grt.std.testing.allocator.free(original);
    const decoded = try grt.std.testing.allocator.alloc(f32, total_samples);
    defer grt.std.testing.allocator.free(decoded);

    var packet_buf: [1500]u8 = undefined;
    for (0..frame_count) |frame_idx| {
        const offset = frame_idx * frame_stride;
        const sample_offset = frame_idx * frame_size;
        const in_frame = original[offset .. offset + frame_stride];
        const out_frame = decoded[offset .. offset + frame_stride];

        fillFloatFrame(in_frame, sample_offset, sample_rate, channels);

        const packet = try encoder.encodeFloat(in_frame, @intCast(frame_size), packet_buf[0..]);
        try grt.std.testing.expect(packet.len > 0);
        try grt.std.testing.expectEqual(channels, try Packet.getChannels(packet));
        try grt.std.testing.expectEqual(@as(u32, 1), try Packet.getFrames(packet));
        try grt.std.testing.expectEqual(@as(u32, @intCast(frame_size)), try Packet.getSamples(packet, sample_rate));

        const samples = try decoder.decodeFloat(packet, out_frame, false);
        try grt.std.testing.expectEqual(frame_stride, samples.len);
    }

    const plc_buf = try grt.std.testing.allocator.alloc(f32, frame_stride);
    defer grt.std.testing.allocator.free(plc_buf);
    const concealed = try decoder.plcFloat(plc_buf);
    try grt.std.testing.expectEqual(frame_stride, concealed.len);

    const metrics = compareFloatPcmInterleaved(original, decoded, channel_count, 512);
    try grt.std.testing.expect(metrics.best_shift <= 512);
    try grt.std.testing.expect(metrics.correlation > 0.50);
    try grt.std.testing.expect(metrics.mean_abs_error < 0.65);
    try grt.std.testing.expect(metrics.energy_ratio > 0.05);
    try grt.std.testing.expect(metrics.energy_ratio < 2.50);
}

const Comparison = struct {
    best_shift: usize,
    correlation: f64,
    mean_abs_error: f64,
    energy_ratio: f64,
};

fn comparePcmInterleaved(input: []const i16, output: []const i16, channels: usize, max_shift: usize) Comparison {
    var best = Comparison{
        .best_shift = 0,
        .correlation = -1.0,
        .mean_abs_error = 0.0,
        .energy_ratio = 0.0,
    };

    const limit = @min(max_shift, (output.len - 1) / channels);
    for (0..limit + 1) |shift_frames| {
        const shift = shift_frames * channels;
        const overlap = @min(input.len, output.len - shift);
        if (overlap == 0) continue;

        var dot: f64 = 0.0;
        var input_energy: f64 = 0.0;
        var output_energy: f64 = 0.0;
        var abs_error_sum: f64 = 0.0;

        for (0..overlap) |i| {
            const a_i16 = input[i];
            const b_i16 = output[i + shift];
            const a = @as(f64, @floatFromInt(a_i16));
            const b = @as(f64, @floatFromInt(b_i16));
            dot += a * b;
            input_energy += a * a;
            output_energy += b * b;

            const diff: i32 = @as(i32, a_i16) - @as(i32, b_i16);
            abs_error_sum += @as(f64, @floatFromInt(if (diff < 0) -diff else diff));
        }

        if (input_energy == 0.0 or output_energy == 0.0) continue;

        const correlation = dot / @sqrt(input_energy * output_energy);
        if (correlation > best.correlation) {
            best = .{
                .best_shift = shift_frames,
                .correlation = correlation,
                .mean_abs_error = abs_error_sum / @as(f64, @floatFromInt(overlap)),
                .energy_ratio = output_energy / input_energy,
            };
        }
    }

    return best;
}

fn compareFloatPcmInterleaved(input: []const f32, output: []const f32, channels: usize, max_shift: usize) Comparison {
    var best = Comparison{
        .best_shift = 0,
        .correlation = -1.0,
        .mean_abs_error = 0.0,
        .energy_ratio = 0.0,
    };

    const limit = @min(max_shift, (output.len - 1) / channels);
    for (0..limit + 1) |shift_frames| {
        const shift = shift_frames * channels;
        const overlap = @min(input.len, output.len - shift);
        if (overlap == 0) continue;

        var dot: f64 = 0.0;
        var input_energy: f64 = 0.0;
        var output_energy: f64 = 0.0;
        var abs_error_sum: f64 = 0.0;

        for (0..overlap) |i| {
            const a = @as(f64, input[i]);
            const b = @as(f64, output[i + shift]);
            dot += a * b;
            input_energy += a * a;
            output_energy += b * b;
            abs_error_sum += @abs(a - b);
        }

        if (input_energy == 0.0 or output_energy == 0.0) continue;

        const correlation = dot / @sqrt(input_energy * output_energy);
        if (correlation > best.correlation) {
            best = .{
                .best_shift = shift_frames,
                .correlation = correlation,
                .mean_abs_error = abs_error_sum / @as(f64, @floatFromInt(overlap)),
                .energy_ratio = output_energy / input_energy,
            };
        }
    }

    return best;
}

fn fillMusicFrame(frame: []i16, sample_offset: usize, sample_rate: u32, channels: u8) void {
    const channel_count: usize = channels;
    if (channels == 1) {
        for (frame, 0..) |*sample, i| {
            sample.* = synthSample(sample_offset + i, sample_rate, 0);
        }
        return;
    }

    for (0..frame.len / channel_count) |i| {
        const pos = sample_offset + i;
        frame[i * channel_count] = synthSample(pos, sample_rate, 0);
        frame[i * channel_count + 1] = synthSample(pos, sample_rate, 1);
    }
}

fn fillFloatFrame(frame: []f32, sample_offset: usize, sample_rate: u32, channels: u8) void {
    const channel_count: usize = channels;
    if (channels == 1) {
        for (frame, 0..) |*sample, i| {
            sample.* = @as(f32, @floatFromInt(synthSample(sample_offset + i, sample_rate, 0))) / 32768.0;
        }
        return;
    }

    for (0..frame.len / channel_count) |i| {
        const pos = sample_offset + i;
        frame[i * channel_count] = @as(f32, @floatFromInt(synthSample(pos, sample_rate, 0))) / 32768.0;
        frame[i * channel_count + 1] = @as(f32, @floatFromInt(synthSample(pos, sample_rate, 1))) / 32768.0;
    }
}

fn synthSample(sample_index: usize, sample_rate: u32, lane: u8) i16 {
    const melody = [_]u32{ 262, 294, 330, 392, 440, 392, 330, 294, 262, 330 };
    const note_window: usize = sample_rate / 2;
    const beat_window: usize = sample_rate / 4;
    const note_idx = (sample_index / note_window) % melody.len;
    const primary = melody[(note_idx + lane) % melody.len];
    const harmony = melody[(note_idx + 2 + lane) % melody.len] / 2;

    var mixed: i32 = 0;
    mixed += triangleWave(sample_index, primary, sample_rate, 11_000);
    mixed += triangleWave(sample_index, harmony, sample_rate, 5_000);
    mixed += triangleWave(sample_index, primary * 2, sample_rate, 1_800);

    const beat_phase = sample_index % beat_window;
    const env_num: i32 = @intCast(beat_window - beat_phase + beat_window / 3);
    const env_den: i32 = @intCast(beat_window + beat_window / 3);
    mixed = @divTrunc(mixed * env_num, env_den);

    return clampI16(mixed);
}

fn triangleWave(sample_index: usize, hz: u32, sample_rate: u32, amplitude: i32) i32 {
    const cycle = @as(u64, sample_rate) * 2;
    const phase = (@as(u64, @intCast(sample_index)) * hz * 2) % cycle;
    const ramp = if (phase < sample_rate) phase else cycle - phase;
    const centered = @as(i64, @intCast(ramp)) * 2 - sample_rate;
    return @intCast(@divTrunc(centered * amplitude, sample_rate));
}

fn clampI16(value: i32) i16 {
    return @intCast(@max(@as(i32, -32768), @min(@as(i32, 32767), value)));
}
