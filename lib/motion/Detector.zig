const types = @import("types.zig");

const Detector = @This();

const pi: f32 = 3.141592653589793;
const half_pi: f32 = pi / 2.0;
const degrees_per_radian: f32 = 57.29577951308232;
const action_queue_capacity: usize = 4;

pub const AccelData = types.AccelData;
pub const Sample = types.Sample;
pub const ShakeData = types.ShakeData;
pub const TiltData = types.TiltData;
pub const Action = types.Action;
pub const Thresholds = types.Thresholds;

pub const ShakeState = struct {
    prev_mag: ?f32 = null,
    active: bool = false,
    start_time_ms: u64 = 0,
    peak_delta: f32 = 0,
    sample_count: u32 = 0,
};

pub const TiltState = struct {
    initialized: bool = false,
    last_roll: f32 = 0,
    last_pitch: f32 = 0,
    last_event_time_ms: u64 = 0,
};

thresholds: Thresholds,
shake_state: ShakeState = .{},
tilt_state: TiltState = .{},
actions: [action_queue_capacity]?Action = [_]?Action{null} ** action_queue_capacity,
read_idx: usize = 0,
count: usize = 0,

pub fn init(thresholds: Thresholds) Detector {
    return .{
        .thresholds = thresholds,
    };
}

pub fn initDefault() Detector {
    return init(Thresholds.default);
}

pub fn reset(self: *Detector) void {
    self.shake_state = .{};
    self.tilt_state = .{};
    self.actions = [_]?Action{null} ** action_queue_capacity;
    self.read_idx = 0;
    self.count = 0;
}

pub fn update(self: *Detector, sample: Sample) ?Action {
    self.detectShake(sample);
    self.detectTilt(sample);
    return self.nextAction();
}

pub fn nextAction(self: *Detector) ?Action {
    if (self.count == 0) return null;

    const idx: usize = self.read_idx;
    const action = self.actions[idx];
    self.actions[idx] = null;
    self.read_idx = (self.read_idx + 1) % action_queue_capacity;
    self.count -= 1;
    return action;
}

pub fn hasPendingActions(self: *const Detector) bool {
    return self.count != 0;
}

fn queueAction(self: *Detector, action: Action) void {
    const idx = (self.read_idx + self.count) % action_queue_capacity;
    self.actions[idx] = action;
    if (self.count >= action_queue_capacity) {
        // Keep the newest fixed-capacity window by discarding the oldest item.
        self.read_idx = (self.read_idx + 1) % action_queue_capacity;
        return;
    }
    self.count += 1;
}

fn detectShake(self: *Detector, sample: Sample) void {
    const mag = sample.accel.magnitude();

    if (self.shake_state.prev_mag == null) {
        self.shake_state.prev_mag = mag;
        return;
    }

    const prev_mag = self.shake_state.prev_mag.?;
    const delta = absf(mag - prev_mag);
    self.shake_state.prev_mag = mag;

    if (delta > self.thresholds.shake_threshold_g * 0.5) {
        if (!self.shake_state.active) {
            self.shake_state.active = true;
            self.shake_state.start_time_ms = sample.timestamp_ms;
            self.shake_state.peak_delta = delta;
            self.shake_state.sample_count = 1;
        } else {
            self.shake_state.peak_delta = maxf(self.shake_state.peak_delta, delta);
            self.shake_state.sample_count += 1;
        }
    }

    if (!self.shake_state.active) return;

    const duration_ms = sample.timestamp_ms -| self.shake_state.start_time_ms;
    if (duration_ms > self.thresholds.shake_max_duration_ms or
        (delta < self.thresholds.shake_threshold_g * 0.2 and
            duration_ms > self.thresholds.shake_min_duration_ms))
    {
        if (duration_ms >= self.thresholds.shake_min_duration_ms and
            self.shake_state.peak_delta >= self.thresholds.shake_threshold_g)
        {
            self.queueAction(.{
                .shake = .{
                    .magnitude = self.shake_state.peak_delta,
                    .duration_ms = saturatingU32(duration_ms),
                },
            });
        }

        self.shake_state.active = false;
        self.shake_state.peak_delta = 0;
        self.shake_state.sample_count = 0;
    }
}

fn detectTilt(self: *Detector, sample: Sample) void {
    const roll = atan2Approx(sample.accel.y, sample.accel.z) * degrees_per_radian;
    const pitch = atan2Approx(-sample.accel.x, @sqrt(sample.accel.y * sample.accel.y + sample.accel.z * sample.accel.z)) * degrees_per_radian;

    if (!self.tilt_state.initialized) {
        self.tilt_state.last_roll = roll;
        self.tilt_state.last_pitch = pitch;
        self.tilt_state.initialized = true;
        return;
    }

    const roll_delta = absf(roll - self.tilt_state.last_roll);
    const pitch_delta = absf(pitch - self.tilt_state.last_pitch);

    if ((roll_delta >= self.thresholds.tilt_threshold_deg or
        pitch_delta >= self.thresholds.tilt_threshold_deg) and
        sample.timestamp_ms -| self.tilt_state.last_event_time_ms >= self.thresholds.tilt_debounce_ms)
    {
        self.queueAction(.{
            .tilt = .{
                .roll = roll,
                .pitch = pitch,
            },
        });
        self.tilt_state.last_roll = roll;
        self.tilt_state.last_pitch = pitch;
        self.tilt_state.last_event_time_ms = sample.timestamp_ms;
    }
}

fn absf(x: f32) f32 {
    return if (x < 0) -x else x;
}

fn maxf(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

fn saturatingU32(value: u64) u32 {
    const max_u32: u64 = 4294967295;
    if (value >= max_u32) return max_u32;
    return @intCast(value);
}

fn atanApproxUnit(x: f32) f32 {
    const ax = absf(x);
    return (pi / 4.0) * x - x * (ax - 1.0) * (0.2447 + 0.0663 * ax);
}

fn atanApprox(x: f32) f32 {
    if (x > 1.0) return half_pi - atanApproxUnit(1.0 / x);
    if (x < -1.0) return -half_pi - atanApproxUnit(1.0 / x);
    return atanApproxUnit(x);
}

fn atan2Approx(y: f32, x: f32) f32 {
    if (x > 0) return atanApprox(y / x);
    if (x < 0 and y >= 0) return atanApprox(y / x) + pi;
    if (x < 0 and y < 0) return atanApprox(y / x) - pi;
    if (x == 0 and y > 0) return half_pi;
    if (x == 0 and y < 0) return -half_pi;
    return 0.0;
}

test "motion/Detector/unit_tests/first_sample_only_seeds_baseline" {
    const std = @import("std");

    var detector = Detector.initDefault();
    try std.testing.expect(detector.update(.{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .timestamp_ms = 0,
    }) == null);
    try std.testing.expect(!detector.hasPendingActions());
}

test "motion/Detector/unit_tests/shake_emits_after_activity_returns_quiet" {
    const std = @import("std");

    var detector = Detector.init(.{
        .shake_threshold_g = 1.0,
        .shake_min_duration_ms = 50,
        .shake_max_duration_ms = 500,
        .tilt_threshold_deg = 9999,
    });

    try std.testing.expect(detector.update(.{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .timestamp_ms = 0,
    }) == null);
    try std.testing.expect(detector.update(.{
        .accel = .{ .x = 2.0, .y = 0, .z = 1.0 },
        .timestamp_ms = 10,
    }) == null);
    try std.testing.expect(detector.update(.{
        .accel = .{ .x = -2.0, .y = 0, .z = 1.0 },
        .timestamp_ms = 20,
    }) == null);
    try std.testing.expect(detector.update(.{
        .accel = .{ .x = 2.0, .y = 0, .z = 1.0 },
        .timestamp_ms = 30,
    }) == null);

    try std.testing.expect(detector.update(.{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .timestamp_ms = 80,
    }) == null);

    const action = detector.update(.{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .timestamp_ms = 140,
    }).?;

    switch (action) {
        .shake => |shake| {
            try std.testing.expect(shake.magnitude >= 1.0);
            try std.testing.expect(shake.duration_ms >= 50);
        },
        else => try std.testing.expect(false),
    }
}

test "motion/Detector/unit_tests/tilt_emits_absolute_angles" {
    const std = @import("std");

    var detector = Detector.init(.{
        .shake_threshold_g = 9999,
        .tilt_threshold_deg = 5.0,
        .tilt_debounce_ms = 0,
    });

    try std.testing.expect(detector.update(.{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .timestamp_ms = 0,
    }) == null);

    const action = detector.update(.{
        .accel = .{ .x = 0.5, .y = 0, .z = 0.866 },
        .timestamp_ms = 100,
    }).?;

    switch (action) {
        .tilt => |tilt| {
            try std.testing.expect(absf(tilt.pitch) > 20.0);
        },
        else => try std.testing.expect(false),
    }
}

test "motion/Detector/unit_tests/tilt_debounce_blocks_rapid_repeat" {
    const std = @import("std");

    var detector = Detector.init(.{
        .shake_threshold_g = 9999,
        .tilt_threshold_deg = 5.0,
        .tilt_debounce_ms = 200,
    });

    try std.testing.expect(detector.update(.{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .timestamp_ms = 0,
    }) == null);

    _ = detector.update(.{
        .accel = .{ .x = 0.5, .y = 0, .z = 0.866 },
        .timestamp_ms = 100,
    });
    try std.testing.expect(!detector.hasPendingActions());

    try std.testing.expect(detector.update(.{
        .accel = .{ .x = 0.7, .y = 0, .z = 0.714 },
        .timestamp_ms = 150,
    }) == null);
    try std.testing.expect(!detector.hasPendingActions());
}

test "motion/Detector/unit_tests/speaker_like_small_vibration_stays_quiet" {
    const std = @import("std");

    var detector = Detector.init(.{
        .shake_threshold_g = 1.0,
        .shake_min_duration_ms = 50,
        .shake_max_duration_ms = 500,
        .tilt_threshold_deg = 9999,
    });

    try std.testing.expect(detector.update(.{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .timestamp_ms = 0,
    }) == null);

    inline for ([_]struct { ts: u64, x: f32 }{
        .{ .ts = 10, .x = 0.30 },
        .{ .ts = 20, .x = 0.00 },
        .{ .ts = 30, .x = 0.30 },
        .{ .ts = 40, .x = 0.00 },
        .{ .ts = 50, .x = 0.30 },
        .{ .ts = 60, .x = 0.00 },
        .{ .ts = 70, .x = 0.30 },
        .{ .ts = 80, .x = 0.00 },
        .{ .ts = 120, .x = 0.00 },
        .{ .ts = 180, .x = 0.00 },
    }) |sample| {
        try std.testing.expect(detector.update(.{
            .accel = .{ .x = sample.x, .y = 0, .z = 1.0 },
            .timestamp_ms = sample.ts,
        }) == null);
        try std.testing.expect(!detector.hasPendingActions());
    }
}

test "motion/Detector/unit_tests/slow_reorientation_does_not_look_like_shake" {
    const std = @import("std");

    var detector = Detector.init(.{
        .shake_threshold_g = 1.0,
        .shake_min_duration_ms = 50,
        .shake_max_duration_ms = 500,
        .tilt_threshold_deg = 9999,
    });

    inline for ([_]Sample{
        .{ .accel = .{ .x = 0.0000, .y = 0, .z = 1.0000 }, .timestamp_ms = 0 },
        .{ .accel = .{ .x = 0.1736, .y = 0, .z = 0.9848 }, .timestamp_ms = 100 },
        .{ .accel = .{ .x = 0.3420, .y = 0, .z = 0.9397 }, .timestamp_ms = 200 },
        .{ .accel = .{ .x = 0.5000, .y = 0, .z = 0.8660 }, .timestamp_ms = 300 },
        .{ .accel = .{ .x = 0.6428, .y = 0, .z = 0.7660 }, .timestamp_ms = 400 },
    }) |sample| {
        try std.testing.expect(detector.update(sample) == null);
        try std.testing.expect(!detector.hasPendingActions());
    }
}

test "motion/Detector/unit_tests/human_shake_still_wins_after_small_vibration_noise" {
    const std = @import("std");

    var detector = Detector.init(.{
        .shake_threshold_g = 1.0,
        .shake_min_duration_ms = 50,
        .shake_max_duration_ms = 500,
        .tilt_threshold_deg = 9999,
    });

    inline for ([_]Sample{
        .{ .accel = .{ .x = 0.0, .y = 0, .z = 1.0 }, .timestamp_ms = 0 },
        .{ .accel = .{ .x = 0.3, .y = 0, .z = 1.0 }, .timestamp_ms = 10 },
        .{ .accel = .{ .x = 0.0, .y = 0, .z = 1.0 }, .timestamp_ms = 20 },
        .{ .accel = .{ .x = 0.3, .y = 0, .z = 1.0 }, .timestamp_ms = 30 },
        .{ .accel = .{ .x = 0.0, .y = 0, .z = 1.0 }, .timestamp_ms = 40 },
        .{ .accel = .{ .x = 2.0, .y = 0, .z = 1.0 }, .timestamp_ms = 60 },
        .{ .accel = .{ .x = 2.0, .y = 0, .z = 1.0 }, .timestamp_ms = 90 },
        .{ .accel = .{ .x = 0.0, .y = 0, .z = 1.0 }, .timestamp_ms = 140 },
    }) |sample| {
        try std.testing.expect(detector.update(sample) == null);
    }

    const action = detector.update(.{
        .accel = .{ .x = 0.0, .y = 0, .z = 1.0 },
        .timestamp_ms = 220,
    }).?;

    switch (action) {
        .shake => |shake| {
            try std.testing.expect(shake.magnitude >= 1.0);
            try std.testing.expect(shake.duration_ms >= 80);
        },
        else => try std.testing.expect(false),
    }
    try std.testing.expect(!detector.hasPendingActions());
}

test "motion/Detector/unit_tests/tilt_can_fire_again_after_debounce_window" {
    const std = @import("std");

    var detector = Detector.init(.{
        .shake_threshold_g = 9999,
        .tilt_threshold_deg = 5.0,
        .tilt_debounce_ms = 200,
    });

    try std.testing.expect(detector.update(.{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .timestamp_ms = 0,
    }) == null);

    try std.testing.expect(detector.update(.{
        .accel = .{ .x = 0.5, .y = 0, .z = 0.866 },
        .timestamp_ms = 100,
    }) == null);
    try std.testing.expect(!detector.hasPendingActions());

    const action = detector.update(.{
        .accel = .{ .x = 0.7, .y = 0, .z = 0.714 },
        .timestamp_ms = 250,
    }).?;

    switch (action) {
        .tilt => |tilt| {
            try std.testing.expect(absf(tilt.pitch) > 20.0);
        },
        else => try std.testing.expect(false),
    }
}

test "motion/Detector/unit_tests/queue_overflow_drops_oldest_action" {
    const std = @import("std");

    var detector = Detector.initDefault();

    detector.queueAction(.{ .shake = .{ .magnitude = 1.0, .duration_ms = 1 } });
    detector.queueAction(.{ .shake = .{ .magnitude = 2.0, .duration_ms = 2 } });
    detector.queueAction(.{ .shake = .{ .magnitude = 3.0, .duration_ms = 3 } });
    detector.queueAction(.{ .shake = .{ .magnitude = 4.0, .duration_ms = 4 } });
    detector.queueAction(.{ .shake = .{ .magnitude = 5.0, .duration_ms = 5 } });

    try std.testing.expectEqual(@as(usize, action_queue_capacity), detector.count);

    const first = detector.nextAction().?;
    const second = detector.nextAction().?;
    const third = detector.nextAction().?;
    const fourth = detector.nextAction().?;

    try expectShakeDuration(first, 2);
    try expectShakeDuration(second, 3);
    try expectShakeDuration(third, 4);
    try expectShakeDuration(fourth, 5);
    try std.testing.expect(detector.nextAction() == null);
}

test "motion/Detector/unit_tests/queue_overflow_after_wrap_preserves_fifo_order" {
    const std = @import("std");

    var detector = Detector.initDefault();

    detector.queueAction(.{ .shake = .{ .magnitude = 1.0, .duration_ms = 1 } });
    detector.queueAction(.{ .shake = .{ .magnitude = 2.0, .duration_ms = 2 } });
    detector.queueAction(.{ .shake = .{ .magnitude = 3.0, .duration_ms = 3 } });
    detector.queueAction(.{ .shake = .{ .magnitude = 4.0, .duration_ms = 4 } });

    try expectShakeDuration(detector.nextAction().?, 1);

    detector.queueAction(.{ .shake = .{ .magnitude = 5.0, .duration_ms = 5 } });
    detector.queueAction(.{ .shake = .{ .magnitude = 6.0, .duration_ms = 6 } });

    try std.testing.expectEqual(@as(usize, action_queue_capacity), detector.count);
    try expectShakeDuration(detector.nextAction().?, 3);
    try expectShakeDuration(detector.nextAction().?, 4);
    try expectShakeDuration(detector.nextAction().?, 5);
    try expectShakeDuration(detector.nextAction().?, 6);
    try std.testing.expect(detector.nextAction() == null);
}

fn expectShakeDuration(action: Action, expected_duration_ms: u32) !void {
    const std = @import("std");

    switch (action) {
        .shake => |shake| try std.testing.expectEqual(expected_duration_ms, shake.duration_ms),
        else => try std.testing.expect(false),
    }
}
