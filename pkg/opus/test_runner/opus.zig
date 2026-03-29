const embed = @import("embed");
const testing_api = @import("testing");
const binding = @import("../src/binding.zig");
const types_mod = @import("../src/types.zig");
const EncoderMod = @import("../src/Encoder.zig");
const DecoderMod = @import("../src/Decoder.zig");
const PacketMod = @import("../src/packet.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            runImpl(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}

fn runImpl(comptime lib: type) !void {
    const opus = struct {
        pub const Application = types_mod.Application;
        pub const Bandwidth = types_mod.Bandwidth;
        pub const Encoder = EncoderMod;
        pub const Decoder = DecoderMod;
        pub const Packet = PacketMod;

        pub fn getVersionString() [*:0]const u8 {
            return binding.getVersionString();
        }
    };
    const testing = lib.testing;

    const sample_rate: u32 = 48_000;
    const frame_ms: u32 = 20;
    const frame_size: usize = 960;
    const seconds: usize = 5;
    const frame_count: usize = seconds * 1000 / frame_ms;
    const total_samples = frame_count * frame_size;

    const version = opus.getVersionString();
    try testing.expect(version[0] != 0);

    var encoder = try opus.Encoder.init(testing.allocator, sample_rate, 1, .audio);
    defer encoder.deinit(testing.allocator);
    var decoder = try opus.Decoder.init(testing.allocator, sample_rate, 1);
    defer decoder.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, frame_size), encoder.frameSizeForMs(frame_ms));
    try testing.expectEqual(@as(u32, frame_size), decoder.frameSizeForMs(frame_ms));

    try encoder.setBitrate(128_000);
    try testing.expect(try encoder.getBitrate() > 0);
    try encoder.setComplexity(10);
    try encoder.setSignal(.music);
    try encoder.setBandwidth(.fullband);
    try encoder.setVbr(false);
    try encoder.setDtx(false);
    try encoder.resetState();
    try testing.expectEqual(sample_rate, try decoder.getSampleRate());

    const original = try testing.allocator.alloc(i16, total_samples);
    defer testing.allocator.free(original);
    const decoded = try testing.allocator.alloc(i16, total_samples);
    defer testing.allocator.free(decoded);

    var packet_buf: [1500]u8 = undefined;
    for (0..frame_count) |frame_idx| {
        const offset = frame_idx * frame_size;
        const in_frame = original[offset .. offset + frame_size];
        const out_frame = decoded[offset .. offset + frame_size];

        fillMusicFrame(in_frame, offset, sample_rate);

        const packet = try encoder.encode(in_frame, frame_size, packet_buf[0..]);
        try testing.expect(packet.len > 0);
        try testing.expectEqual(@as(u8, 1), try opus.Packet.getChannels(packet));
        try testing.expectEqual(@as(u32, 1), try opus.Packet.getFrames(packet));
        try testing.expectEqual(@as(u32, frame_size), try opus.Packet.getSamples(packet, sample_rate));

        const samples = try decoder.decode(packet, out_frame, false);
        try testing.expectEqual(frame_size, samples.len);
    }

    const metrics = comparePcm(original, decoded, 512);
    try testing.expect(metrics.best_shift <= 512);
    try testing.expect(metrics.correlation > 0.82);
    try testing.expect(metrics.mean_abs_error < 4_500.0);
    try testing.expect(metrics.energy_ratio > 0.15);
    try testing.expect(metrics.energy_ratio < 1.80);
}

const Comparison = struct {
    best_shift: usize,
    correlation: f64,
    mean_abs_error: f64,
    energy_ratio: f64,
};

fn comparePcm(input: []const i16, output: []const i16, max_shift: usize) Comparison {
    var best = Comparison{
        .best_shift = 0,
        .correlation = -1.0,
        .mean_abs_error = 0.0,
        .energy_ratio = 0.0,
    };

    const limit = @min(max_shift, output.len - 1);
    for (0..limit + 1) |shift| {
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
                .best_shift = shift,
                .correlation = correlation,
                .mean_abs_error = abs_error_sum / @as(f64, @floatFromInt(overlap)),
                .energy_ratio = output_energy / input_energy,
            };
        }
    }

    return best;
}

fn fillMusicFrame(frame: []i16, sample_offset: usize, sample_rate: u32) void {
    const melody = [_]u32{ 262, 294, 330, 392, 440, 392, 330, 294, 262, 330 };
    const note_window: usize = sample_rate / 2;
    const beat_window: usize = sample_rate / 4;

    for (frame, 0..) |*sample, i| {
        const pos = sample_offset + i;
        const note_idx = (pos / note_window) % melody.len;
        const primary = melody[note_idx];
        const harmony = melody[(note_idx + 2) % melody.len] / 2;

        var mixed: i32 = 0;
        mixed += triangleWave(pos, primary, sample_rate, 11_000);
        mixed += triangleWave(pos, harmony, sample_rate, 5_000);
        mixed += triangleWave(pos, primary * 2, sample_rate, 1_800);

        const beat_phase = pos % beat_window;
        const env_num: i32 = @intCast(beat_window - beat_phase + beat_window / 3);
        const env_den: i32 = @intCast(beat_window + beat_window / 3);
        mixed = @divTrunc(mixed * env_num, env_den);

        sample.* = clampI16(mixed);
    }
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
