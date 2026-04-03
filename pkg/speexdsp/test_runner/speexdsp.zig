const embed = @import("embed");
const testing_api = @import("testing");
const std = @import("std");
const types = @import("../src/types.zig");
const EchoState = @import("../src/EchoState.zig");
const PreprocessState = @import("../src/PreprocessState.zig");
const Resampler = @import("../src/Resampler.zig");

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
    const testing = lib.testing;
    const matrix_report = shouldReportMatrix();

    var echo = try EchoState.init(160, 1600);
    defer echo.deinit();
    try echo.setSamplingRate(16_000);
    try testing.expectEqual(@as(u32, 16_000), try echo.samplingRate());
    const synthetic_metrics = try runSyntheticAecScenario(lib, &echo);
    maybeReportAecMetric(matrix_report, "synthetic", synthetic_metrics);
    try expectAecImprovement(synthetic_metrics, 85, error.SyntheticAecTooWeak);
    echo.reset();
    const playback_metrics = try runPlaybackCaptureScenario(lib, &echo);
    maybeReportAecMetric(matrix_report, "playback_capture", playback_metrics);
    try expectAecImprovement(playback_metrics, 95, error.PlaybackCaptureAecTooWeak);
    try runResetRegressionScenario(lib, matrix_report);
    echo.reset();

    var preprocess = try PreprocessState.init(160, 16_000);
    defer preprocess.deinit();
    try preprocess.setDenoise(true);
    try preprocess.setNoiseSuppress(-30);
    try preprocess.setEchoSuppress(-45);
    try preprocess.setEchoSuppressActive(-15);
    try preprocess.setEchoState(&echo);

    var preprocess_frame = [_]types.Sample{0} ** 160;
    fillDeterministicNoise(preprocess_frame[0..], 0x1A2B3C4D, 128);
    _ = try preprocess.run(preprocess_frame[0..]);
    try preprocess.estimateUpdate(preprocess_frame[0..]);
    try preprocess.clearEchoState();

    var resampler = try Resampler.init(1, 16_000, 8_000, types.resampler_quality_default);
    defer resampler.deinit();

    const rates = resampler.getRate();
    try testing.expectEqual(@as(u32, 16_000), rates.in_rate);
    try testing.expectEqual(@as(u32, 8_000), rates.out_rate);
    try testing.expectEqual(types.resampler_quality_default, resampler.getQuality());

    try resampler.skipZeros();
    var resampled = [_]types.Sample{0} ** 160;
    const result = try resampler.processInterleavedInt(preprocess_frame[0..], resampled[0..]);
    const channels: usize = @intCast(resampler.channelCount());
    try testing.expect(result.input_frames_consumed <= preprocess_frame.len / channels);
    try testing.expect(result.output_frames_produced <= resampled.len / channels);

    var channel_resampled = [_]types.Sample{0} ** 160;
    const direct_result = try resampler.processInt(0, preprocess_frame[0..], channel_resampled[0..]);
    if (!(direct_result.input_consumed <= preprocess_frame.len)) return error.ResamplerDirectInputAccounting;
    if (!(direct_result.output_produced <= channel_resampled.len)) return error.ResamplerDirectOutputAccounting;

    try resampler.setRate(8_000, 16_000);
    const updated = resampler.getRate();
    try testing.expectEqual(@as(u32, 8_000), updated.in_rate);
    try testing.expectEqual(@as(u32, 16_000), updated.out_rate);
    try resampler.setQuality(types.resampler_quality_voip);
    try testing.expectEqual(types.resampler_quality_voip, resampler.getQuality());
    try resampler.reset();
    _ = resampler.inputLatency();
    _ = resampler.outputLatency();
}

const AecMetrics = struct {
    input_residual_energy: i64,
    output_residual_energy: i64,
};

fn runSyntheticAecScenario(comptime lib: type, echo: *EchoState) !AecMetrics {
    const testing = lib.testing;
    const frame_size = echo.frameSize();
    const frame_count: usize = 240;
    const warmup_frames: usize = 80;
    const total_samples = frame_size * frame_count;
    const delay_a: usize = 43;
    const delay_b: usize = 97;

    const play = try testing.allocator.alloc(types.Sample, total_samples);
    defer testing.allocator.free(play);
    const clean = try testing.allocator.alloc(types.Sample, total_samples);
    defer testing.allocator.free(clean);
    const rec = try testing.allocator.alloc(types.Sample, total_samples);
    defer testing.allocator.free(rec);
    const out = try testing.allocator.alloc(types.Sample, total_samples);
    defer testing.allocator.free(out);

    fillDeterministicNoise(play, 0x1234ABCD, 4);
    fillDeterministicNoise(clean, 0xABCD1234, 20);

    var noise_seed: u32 = 0xCAFEBABE;
    for (0..total_samples) |i| {
        const clean_sample: i32 = clean[i];
        const echo_a: i32 = if (i >= delay_a) @divTrunc(@as(i32, play[i - delay_a]) * 3, 5) else 0;
        const echo_b: i32 = if (i >= delay_b) @divTrunc(@as(i32, play[i - delay_b]), 4) else 0;
        const noise: i32 = @divTrunc(@as(i32, nextPcmSample(&noise_seed)), 256);
        rec[i] = clampToSample(clean_sample + echo_a + echo_b + noise);
    }

    for (0..frame_count) |frame_idx| {
        const offset = frame_idx * frame_size;
        try echo.cancellation(
            rec[offset .. offset + frame_size],
            play[offset .. offset + frame_size],
            out[offset .. offset + frame_size],
        );
    }

    return computeResidualMetrics(rec, clean, out, warmup_frames * frame_size);
}

fn runPlaybackCaptureScenario(comptime lib: type, echo: *EchoState) !AecMetrics {
    const testing = lib.testing;
    const frame_size = echo.frameSize();
    const frame_count: usize = 320;
    const warmup_frames: usize = 140;
    const total_samples = frame_size * frame_count;
    const playback_delay_samples = 2 * frame_size;

    const play = try testing.allocator.alloc(types.Sample, total_samples);
    defer testing.allocator.free(play);
    const clean = try testing.allocator.alloc(types.Sample, total_samples);
    defer testing.allocator.free(clean);
    const rec = try testing.allocator.alloc(types.Sample, total_samples);
    defer testing.allocator.free(rec);
    const out = try testing.allocator.alloc(types.Sample, total_samples);
    defer testing.allocator.free(out);

    fillDeterministicNoise(play, 0x55667788, 5);
    fillDeterministicNoise(clean, 0x11223344, 28);

    var noise_seed: u32 = 0x10203040;
    for (0..total_samples) |i| {
        const clean_sample: i32 = clean[i];
        const echo_main: i32 = if (i >= playback_delay_samples)
            @divTrunc(@as(i32, play[i - playback_delay_samples]) * 3, 5)
        else
            0;
        const noise: i32 = @divTrunc(@as(i32, nextPcmSample(&noise_seed)), 512);
        rec[i] = clampToSample(clean_sample + echo_main + noise);
    }

    // The real split API is described in upstream docs as playback-side
    // buffering plus capture-side consumption. This runner stays single-owner
    // and deterministic, so it models the delayed internal reference queue
    // directly instead of trying to emulate two concurrent audio threads.
    for (0..frame_count) |frame_idx| {
        const offset = frame_idx * frame_size;
        try echo.capture(
            rec[offset .. offset + frame_size],
            out[offset .. offset + frame_size],
        );
        try echo.playback(play[offset .. offset + frame_size]);
    }

    return computeResidualMetrics(rec, clean, out, warmup_frames * frame_size);
}

fn runResetRegressionScenario(comptime lib: type, matrix_report: bool) !void {
    const testing = lib.testing;
    const frame_size: usize = 160;
    const total_samples = frame_size * 240;

    var dirty_echo = try EchoState.init(frame_size, 1600);
    defer dirty_echo.deinit();
    try dirty_echo.setSamplingRate(16_000);

    var fresh_echo = try EchoState.init(frame_size, 1600);
    defer fresh_echo.deinit();
    try fresh_echo.setSamplingRate(16_000);

    _ = try runSyntheticAecScenario(lib, &dirty_echo);
    dirty_echo.reset();

    const dirty_out = try testing.allocator.alloc(types.Sample, total_samples);
    defer testing.allocator.free(dirty_out);
    const fresh_out = try testing.allocator.alloc(types.Sample, total_samples);
    defer testing.allocator.free(fresh_out);

    const dirty_metrics = try runSyntheticAecScenarioInto(lib, &dirty_echo, dirty_out);
    const fresh_metrics = try runSyntheticAecScenarioInto(lib, &fresh_echo, fresh_out);

    maybeReportAecMetric(matrix_report, "reset_dirty", dirty_metrics);
    maybeReportAecMetric(matrix_report, "reset_fresh", fresh_metrics);
    try expectAecImprovement(dirty_metrics, 85, error.DirtyResetAecTooWeak);
    try expectAecImprovement(fresh_metrics, 85, error.FreshResetAecTooWeak);
    try expectComparableResidualRatios(fresh_metrics, dirty_metrics, 12);
}

fn runSyntheticAecScenarioInto(comptime lib: type, echo: *EchoState, out: []types.Sample) !AecMetrics {
    const testing = lib.testing;
    const frame_size = echo.frameSize();
    const frame_count: usize = 240;
    const warmup_frames: usize = 80;
    const total_samples = frame_size * frame_count;
    const delay_a: usize = 43;
    const delay_b: usize = 97;

    if (out.len != total_samples) return error.InvalidOutputBuffer;

    const play = try testing.allocator.alloc(types.Sample, total_samples);
    defer testing.allocator.free(play);
    const clean = try testing.allocator.alloc(types.Sample, total_samples);
    defer testing.allocator.free(clean);
    const rec = try testing.allocator.alloc(types.Sample, total_samples);
    defer testing.allocator.free(rec);

    fillDeterministicNoise(play, 0x1234ABCD, 4);
    fillDeterministicNoise(clean, 0xABCD1234, 20);

    var noise_seed: u32 = 0xCAFEBABE;
    for (0..total_samples) |i| {
        const clean_sample: i32 = clean[i];
        const echo_a: i32 = if (i >= delay_a) @divTrunc(@as(i32, play[i - delay_a]) * 3, 5) else 0;
        const echo_b: i32 = if (i >= delay_b) @divTrunc(@as(i32, play[i - delay_b]), 4) else 0;
        const noise: i32 = @divTrunc(@as(i32, nextPcmSample(&noise_seed)), 256);
        rec[i] = clampToSample(clean_sample + echo_a + echo_b + noise);
    }

    for (0..frame_count) |frame_idx| {
        const offset = frame_idx * frame_size;
        try echo.cancellation(
            rec[offset .. offset + frame_size],
            play[offset .. offset + frame_size],
            out[offset .. offset + frame_size],
        );
    }

    return computeResidualMetrics(rec, clean, out, warmup_frames * frame_size);
}

fn expectAecImprovement(metrics: AecMetrics, max_residual_percent: i64, comptime too_weak_err: anyerror) !void {
    if (!(metrics.input_residual_energy > 0)) return error.InvalidAecInputResidual;
    if (!(metrics.output_residual_energy > 0)) return error.InvalidAecOutputResidual;
    if (!(metrics.output_residual_energy < metrics.input_residual_energy)) return too_weak_err;
    if (!(metrics.output_residual_energy * 100 <= metrics.input_residual_energy * max_residual_percent)) return too_weak_err;
}

fn expectComparableResidualRatios(reference: AecMetrics, candidate: AecMetrics, max_delta_points: i64) !void {
    if (!(reference.input_residual_energy > 0)) return error.InvalidReferenceResidual;
    if (!(candidate.input_residual_energy > 0)) return error.InvalidCandidateResidual;

    const reference_ratio = @divTrunc(reference.output_residual_energy * 100, reference.input_residual_energy);
    const candidate_ratio = @divTrunc(candidate.output_residual_energy * 100, candidate.input_residual_energy);
    if (!(absI64(reference_ratio - candidate_ratio) <= max_delta_points)) return error.ResetResidualRatioDrift;
}

fn shouldReportMatrix() bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "SPEEXDSP_MATRIX_REPORT") catch return false;
    defer std.heap.page_allocator.free(value);
    return value.len != 0;
}

fn maybeReportAecMetric(enabled: bool, scenario: []const u8, metrics: AecMetrics) void {
    if (!enabled) return;
    if (metrics.input_residual_energy <= 0) return;

    const residual_percent = @divTrunc(metrics.output_residual_energy * 100, metrics.input_residual_energy);
    const improvement_percent = 100 - residual_percent;
    std.debug.print(
        "SPEEXDSP_METRIC scenario={s} input_residual_energy={} output_residual_energy={} residual_percent={} improvement_percent={}\n",
        .{
            scenario,
            metrics.input_residual_energy,
            metrics.output_residual_energy,
            residual_percent,
            improvement_percent,
        },
    );
}

fn computeResidualMetrics(
    rec: []const types.Sample,
    clean: []const types.Sample,
    out: []const types.Sample,
    eval_start: usize,
) AecMetrics {
    var input_residual_energy: i64 = 0;
    var output_residual_energy: i64 = 0;
    for (eval_start..rec.len) |i| {
        const input_diff: i32 = @as(i32, rec[i]) - @as(i32, clean[i]);
        const output_diff: i32 = @as(i32, out[i]) - @as(i32, clean[i]);
        input_residual_energy += @as(i64, input_diff) * input_diff;
        output_residual_energy += @as(i64, output_diff) * output_diff;
    }
    return .{
        .input_residual_energy = input_residual_energy,
        .output_residual_energy = output_residual_energy,
    };
}

fn fillDeterministicNoise(buf: []types.Sample, seed: u32, divisor: i32) void {
    var state = seed;
    for (buf) |*sample| {
        sample.* = @intCast(@divTrunc(@as(i32, nextPcmSample(&state)), divisor));
    }
}

fn nextPcmSample(state: *u32) i16 {
    state.* = state.* *% 1664525 +% 1013904223;
    const word: u16 = @truncate(state.* >> 16);
    return @bitCast(word);
}

fn clampToSample(value: i32) types.Sample {
    if (value < -32768) return -32768;
    if (value > 32767) return 32767;
    return @intCast(value);
}

fn absI64(value: i64) i64 {
    return if (value < 0) -value else value;
}
