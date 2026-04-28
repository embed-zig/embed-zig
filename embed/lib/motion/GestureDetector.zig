const types = @import("types.zig");
const glib = @import("glib");

const GestureDetector = @This();
const Detector = GestureDetector;

const pi: f32 = 3.141592653589793;
const half_pi: f32 = pi / 2.0;
const degrees_per_radian: f32 = 57.29577951308232;
const action_queue_capacity: usize = 4;

pub const AccelData = types.AccelData;
pub const GyroData = types.GyroData;
pub const Sample = types.Sample;
pub const GyroSample = types.GyroSample;
pub const Face = types.Face;
pub const FlipData = types.FlipData;
pub const FreeFallData = types.FreeFallData;
pub const ShakeData = types.ShakeData;
pub const TiltData = types.TiltData;
pub const Action = types.Action;
pub const Thresholds = types.Thresholds;

pub const ShakeState = struct {
    prev_mag: ?f32 = null,
    active: bool = false,
    start_time: glib.time.instant.Time = 0,
    peak_delta: f32 = 0,
    sample_count: u32 = 0,
};

pub const TiltState = struct {
    initialized: bool = false,
    last_roll: f32 = 0,
    last_pitch: f32 = 0,
    last_event_time: glib.time.instant.Time = 0,
};

pub const FreeFallState = struct {
    active: bool = false,
    emitted: bool = false,
    start_time: glib.time.instant.Time = 0,
    min_magnitude: f32 = 0,
};

pub const FlipState = struct {
    face: ?Face = null,
    saw_turn: bool = false,
    last_turn_time: glib.time.instant.Time = 0,
    last_event_time: glib.time.instant.Time = 0,
};

thresholds: Thresholds,
shake_state: ShakeState = .{},
tilt_state: TiltState = .{},
free_fall_state: FreeFallState = .{},
flip_state: FlipState = .{},
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
    self.free_fall_state = .{};
    self.flip_state = .{};
    self.actions = [_]?Action{null} ** action_queue_capacity;
    self.read_idx = 0;
    self.count = 0;
}

pub fn update(self: *Detector, sample: Sample) ?Action {
    self.detectShake(sample);
    self.detectFreeFall(sample);
    const action_count = self.count;
    self.detectFlip(sample);
    if (self.count == action_count) {
        self.detectTilt(sample);
    } else {
        self.syncTiltBaseline(sample);
    }
    return self.nextAction();
}

pub fn updateGyro(self: *Detector, sample: GyroSample) ?Action {
    self.detectFlipGyro(sample);
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
            self.shake_state.start_time = sample.timestamp;
            self.shake_state.peak_delta = delta;
            self.shake_state.sample_count = 1;
        } else {
            self.shake_state.peak_delta = maxf(self.shake_state.peak_delta, delta);
            self.shake_state.sample_count += 1;
        }
    }

    if (!self.shake_state.active) return;

    const duration = glib.time.instant.sub(sample.timestamp, self.shake_state.start_time);
    if (duration > self.thresholds.shake_max_duration or
        (delta < self.thresholds.shake_threshold_g * 0.2 and
            duration > self.thresholds.shake_min_duration))
    {
        if (duration >= self.thresholds.shake_min_duration and
            self.shake_state.peak_delta >= self.thresholds.shake_threshold_g)
        {
            self.queueAction(.{
                .shake = .{
                    .magnitude = self.shake_state.peak_delta,
                    .duration = duration,
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
        glib.time.instant.sub(sample.timestamp, self.tilt_state.last_event_time) >= self.thresholds.tilt_debounce)
    {
        self.queueAction(.{
            .tilt = .{
                .roll = roll,
                .pitch = pitch,
            },
        });
        self.tilt_state.last_roll = roll;
        self.tilt_state.last_pitch = pitch;
        self.tilt_state.last_event_time = sample.timestamp;
    }
}

fn detectFreeFall(self: *Detector, sample: Sample) void {
    const mag = sample.accel.magnitude();

    if (mag <= self.thresholds.free_fall_threshold_g) {
        if (!self.free_fall_state.active) {
            self.free_fall_state.active = true;
            self.free_fall_state.emitted = false;
            self.free_fall_state.start_time = sample.timestamp;
            self.free_fall_state.min_magnitude = mag;
            return;
        }

        self.free_fall_state.min_magnitude = minf(self.free_fall_state.min_magnitude, mag);
        const duration = glib.time.instant.sub(sample.timestamp, self.free_fall_state.start_time);
        if (!self.free_fall_state.emitted and
            duration >= self.thresholds.free_fall_min_duration)
        {
            self.queueAction(.{
                .free_fall = .{
                    .duration = duration,
                    .min_magnitude = self.free_fall_state.min_magnitude,
                },
            });
            self.free_fall_state.emitted = true;
        }
        return;
    }

    self.free_fall_state.active = false;
    self.free_fall_state.emitted = false;
    self.free_fall_state.start_time = 0;
    self.free_fall_state.min_magnitude = 0;
}

fn detectFlip(self: *Detector, sample: Sample) void {
    const face = dominantFace(sample.accel) orelse return;

    if (self.flip_state.face) |prev_face| {
        if (prev_face != face and
            self.flip_state.saw_turn and
            glib.time.instant.sub(sample.timestamp, self.flip_state.last_turn_time) <= self.thresholds.flip_recent_turn and
            (self.flip_state.last_event_time == 0 or
                glib.time.instant.sub(sample.timestamp, self.flip_state.last_event_time) >= self.thresholds.flip_debounce))
        {
            self.queueAction(.{
                .flip = .{
                    .from = prev_face,
                    .to = face,
                },
            });
            self.flip_state.last_event_time = sample.timestamp;
        }
    }

    self.flip_state.face = face;
}

fn detectFlipGyro(self: *Detector, sample: GyroSample) void {
    if (sample.gyro.magnitude() < self.thresholds.flip_gyro_threshold_dps) return;

    self.flip_state.saw_turn = true;
    self.flip_state.last_turn_time = sample.timestamp;
}

fn syncTiltBaseline(self: *Detector, sample: Sample) void {
    const roll = atan2Approx(sample.accel.y, sample.accel.z) * degrees_per_radian;
    const pitch = atan2Approx(-sample.accel.x, @sqrt(sample.accel.y * sample.accel.y + sample.accel.z * sample.accel.z)) * degrees_per_radian;

    self.tilt_state.initialized = true;
    self.tilt_state.last_roll = roll;
    self.tilt_state.last_pitch = pitch;
    self.tilt_state.last_event_time = sample.timestamp;
}

fn absf(x: f32) f32 {
    return if (x < 0) -x else x;
}

fn maxf(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

fn minf(a: f32, b: f32) f32 {
    return if (a < b) a else b;
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

fn dominantFace(accel: AccelData) ?Face {
    const mag = accel.magnitude();
    if (mag < 0.6 or mag > 1.4) return null;
    if (absf(accel.x) > 0.45 or absf(accel.y) > 0.45) return null;
    if (accel.z >= 0.75) return .up;
    if (accel.z <= -0.75) return .down;
    return null;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn timestampMs(comptime value: comptime_int) glib.time.instant.Time {
            return @intCast(value * glib.time.duration.MilliSecond);
        }

        fn testFirstSampleOnlySeedsBaseline() !void {
            var detector = Detector.initDefault();
            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(0),
            }) == null);
            try grt.std.testing.expect(!detector.hasPendingActions());
        }
        fn testShakeEmitsAfterActivityReturnsQuiet() !void {
            var detector = Detector.init(.{
                .shake_threshold_g = 1.0,
                .shake_min_duration = 50 * glib.time.duration.MilliSecond,
                .shake_max_duration = 500 * glib.time.duration.MilliSecond,
                .tilt_threshold_deg = 9999,
            });

            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(0),
            }) == null);
            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 2.0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(10),
            }) == null);
            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = -2.0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(20),
            }) == null);
            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 2.0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(30),
            }) == null);

            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(80),
            }) == null);

            const action = detector.update(.{
                .accel = .{ .x = 0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(140),
            }).?;

            switch (action) {
                .shake => |shake| {
                    try grt.std.testing.expect(shake.magnitude >= 1.0);
                    try grt.std.testing.expect(shake.duration >= 50 * glib.time.duration.MilliSecond);
                },
                else => try grt.std.testing.expect(false),
            }
        }
        fn testTiltEmitsAbsoluteAngles() !void {
            var detector = Detector.init(.{
                .shake_threshold_g = 9999,
                .tilt_threshold_deg = 5.0,
                .tilt_debounce = 0 * glib.time.duration.MilliSecond,
            });

            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(0),
            }) == null);

            const action = detector.update(.{
                .accel = .{ .x = 0.5, .y = 0, .z = 0.866 },
                .timestamp = timestampMs(100),
            }).?;

            switch (action) {
                .tilt => |tilt| {
                    try grt.std.testing.expect(absf(tilt.pitch) > 20.0);
                },
                else => try grt.std.testing.expect(false),
            }
        }
        fn testTiltDebounceBlocksRapidRepeat() !void {
            var detector = Detector.init(.{
                .shake_threshold_g = 9999,
                .tilt_threshold_deg = 5.0,
                .tilt_debounce = 200 * glib.time.duration.MilliSecond,
            });

            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(0),
            }) == null);

            _ = detector.update(.{
                .accel = .{ .x = 0.5, .y = 0, .z = 0.866 },
                .timestamp = timestampMs(100),
            });
            try grt.std.testing.expect(!detector.hasPendingActions());

            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0.7, .y = 0, .z = 0.714 },
                .timestamp = timestampMs(150),
            }) == null);
            try grt.std.testing.expect(!detector.hasPendingActions());
        }
        fn testSpeakerLikeSmallVibrationStaysQuiet() !void {
            var detector = Detector.init(.{
                .shake_threshold_g = 1.0,
                .shake_min_duration = 50 * glib.time.duration.MilliSecond,
                .shake_max_duration = 500 * glib.time.duration.MilliSecond,
                .tilt_threshold_deg = 9999,
            });

            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(0),
            }) == null);

            inline for ([_]struct { timestamp: glib.time.instant.Time, x: f32 }{
                .{ .timestamp = timestampMs(10), .x = 0.30 },
                .{ .timestamp = timestampMs(20), .x = 0.00 },
                .{ .timestamp = timestampMs(30), .x = 0.30 },
                .{ .timestamp = timestampMs(40), .x = 0.00 },
                .{ .timestamp = timestampMs(50), .x = 0.30 },
                .{ .timestamp = timestampMs(60), .x = 0.00 },
                .{ .timestamp = timestampMs(70), .x = 0.30 },
                .{ .timestamp = timestampMs(80), .x = 0.00 },
                .{ .timestamp = timestampMs(120), .x = 0.00 },
                .{ .timestamp = timestampMs(180), .x = 0.00 },
            }) |sample| {
                try grt.std.testing.expect(detector.update(.{
                    .accel = .{ .x = sample.x, .y = 0, .z = 1.0 },
                    .timestamp = sample.timestamp,
                }) == null);
                try grt.std.testing.expect(!detector.hasPendingActions());
            }
        }
        fn testSlowReorientationDoesNotLookLikeShake() !void {
            var detector = Detector.init(.{
                .shake_threshold_g = 1.0,
                .shake_min_duration = 50 * glib.time.duration.MilliSecond,
                .shake_max_duration = 500 * glib.time.duration.MilliSecond,
                .tilt_threshold_deg = 9999,
            });

            inline for ([_]Sample{
                .{ .accel = .{ .x = 0.0000, .y = 0, .z = 1.0000 }, .timestamp = timestampMs(0) },
                .{ .accel = .{ .x = 0.1736, .y = 0, .z = 0.9848 }, .timestamp = timestampMs(100) },
                .{ .accel = .{ .x = 0.3420, .y = 0, .z = 0.9397 }, .timestamp = timestampMs(200) },
                .{ .accel = .{ .x = 0.5000, .y = 0, .z = 0.8660 }, .timestamp = timestampMs(300) },
                .{ .accel = .{ .x = 0.6428, .y = 0, .z = 0.7660 }, .timestamp = timestampMs(400) },
            }) |sample| {
                try grt.std.testing.expect(detector.update(sample) == null);
                try grt.std.testing.expect(!detector.hasPendingActions());
            }
        }
        fn testHumanShakeStillWinsAfterSmallVibrationNoise() !void {
            var detector = Detector.init(.{
                .shake_threshold_g = 1.0,
                .shake_min_duration = 50 * glib.time.duration.MilliSecond,
                .shake_max_duration = 500 * glib.time.duration.MilliSecond,
                .tilt_threshold_deg = 9999,
            });

            inline for ([_]Sample{
                .{ .accel = .{ .x = 0.0, .y = 0, .z = 1.0 }, .timestamp = timestampMs(0) },
                .{ .accel = .{ .x = 0.3, .y = 0, .z = 1.0 }, .timestamp = timestampMs(10) },
                .{ .accel = .{ .x = 0.0, .y = 0, .z = 1.0 }, .timestamp = timestampMs(20) },
                .{ .accel = .{ .x = 0.3, .y = 0, .z = 1.0 }, .timestamp = timestampMs(30) },
                .{ .accel = .{ .x = 0.0, .y = 0, .z = 1.0 }, .timestamp = timestampMs(40) },
                .{ .accel = .{ .x = 2.0, .y = 0, .z = 1.0 }, .timestamp = timestampMs(60) },
                .{ .accel = .{ .x = 2.0, .y = 0, .z = 1.0 }, .timestamp = timestampMs(90) },
                .{ .accel = .{ .x = 0.0, .y = 0, .z = 1.0 }, .timestamp = timestampMs(140) },
            }) |sample| {
                try grt.std.testing.expect(detector.update(sample) == null);
            }

            const action = detector.update(.{
                .accel = .{ .x = 0.0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(220),
            }).?;

            switch (action) {
                .shake => |shake| {
                    try grt.std.testing.expect(shake.magnitude >= 1.0);
                    try grt.std.testing.expect(shake.duration >= 80 * glib.time.duration.MilliSecond);
                },
                else => try grt.std.testing.expect(false),
            }
            try grt.std.testing.expect(!detector.hasPendingActions());
        }
        fn testTiltCanFireAgainAfterDebounceWindow() !void {
            var detector = Detector.init(.{
                .shake_threshold_g = 9999,
                .tilt_threshold_deg = 5.0,
                .tilt_debounce = 200 * glib.time.duration.MilliSecond,
            });

            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(0),
            }) == null);

            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0.5, .y = 0, .z = 0.866 },
                .timestamp = timestampMs(100),
            }) == null);
            try grt.std.testing.expect(!detector.hasPendingActions());

            const action = detector.update(.{
                .accel = .{ .x = 0.7, .y = 0, .z = 0.714 },
                .timestamp = timestampMs(250),
            }).?;

            switch (action) {
                .tilt => |tilt| {
                    try grt.std.testing.expect(absf(tilt.pitch) > 20.0);
                },
                else => try grt.std.testing.expect(false),
            }
        }
        fn testFlipNeedsRecentTurnAndFaceChange() !void {
            var detector = Detector.init(.{
                .shake_threshold_g = 9999,
                .tilt_threshold_deg = 9999,
                .flip_gyro_threshold_dps = 90.0,
                .flip_recent_turn = 400 * glib.time.duration.MilliSecond,
                .flip_debounce = 0 * glib.time.duration.MilliSecond,
            });

            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(0),
            }) == null);
            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0, .y = 0, .z = -1.0 },
                .timestamp = timestampMs(100),
            }) == null);

            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(200),
            }) == null);
            try grt.std.testing.expect(detector.updateGyro(.{
                .gyro = .{ .x = 0, .y = 0, .z = 140.0 },
                .timestamp = timestampMs(220),
            }) == null);

            const action = detector.update(.{
                .accel = .{ .x = 0, .y = 0, .z = -1.0 },
                .timestamp = timestampMs(260),
            }).?;

            switch (action) {
                .flip => |flip| {
                    try grt.std.testing.expectEqual(Face.up, flip.from);
                    try grt.std.testing.expectEqual(Face.down, flip.to);
                },
                else => try grt.std.testing.expect(false),
            }
        }
        fn testFreeFallNeedsSustainedLowMagnitude() !void {
            var detector = Detector.init(.{
                .shake_threshold_g = 9999,
                .tilt_threshold_deg = 9999,
                .free_fall_threshold_g = 0.25,
                .free_fall_min_duration = 120 * glib.time.duration.MilliSecond,
            });

            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0, .y = 0, .z = 1.0 },
                .timestamp = timestampMs(0),
            }) == null);
            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0.05, .y = 0.02, .z = 0.08 },
                .timestamp = timestampMs(40),
            }) == null);
            try grt.std.testing.expect(detector.update(.{
                .accel = .{ .x = 0.02, .y = 0.01, .z = 0.06 },
                .timestamp = timestampMs(100),
            }) == null);

            const action = detector.update(.{
                .accel = .{ .x = 0.01, .y = 0.00, .z = 0.04 },
                .timestamp = timestampMs(170),
            }).?;

            switch (action) {
                .free_fall => |free_fall| {
                    try grt.std.testing.expect(free_fall.duration >= 120 * glib.time.duration.MilliSecond);
                    try grt.std.testing.expect(free_fall.min_magnitude <= 0.1);
                },
                else => try grt.std.testing.expect(false),
            }
        }
        fn testQueueOverflowDropsOldestAction() !void {
            var detector = Detector.initDefault();

            detector.queueAction(.{ .shake = .{ .magnitude = 1.0, .duration = 1 * glib.time.duration.MilliSecond } });
            detector.queueAction(.{ .shake = .{ .magnitude = 2.0, .duration = 2 * glib.time.duration.MilliSecond } });
            detector.queueAction(.{ .shake = .{ .magnitude = 3.0, .duration = 3 * glib.time.duration.MilliSecond } });
            detector.queueAction(.{ .shake = .{ .magnitude = 4.0, .duration = 4 * glib.time.duration.MilliSecond } });
            detector.queueAction(.{ .shake = .{ .magnitude = 5.0, .duration = 5 * glib.time.duration.MilliSecond } });

            try grt.std.testing.expectEqual(@as(usize, action_queue_capacity), detector.count);

            const first = detector.nextAction().?;
            const second = detector.nextAction().?;
            const third = detector.nextAction().?;
            const fourth = detector.nextAction().?;

            try expectShakeDuration(first, 2 * glib.time.duration.MilliSecond);
            try expectShakeDuration(second, 3 * glib.time.duration.MilliSecond);
            try expectShakeDuration(third, 4 * glib.time.duration.MilliSecond);
            try expectShakeDuration(fourth, 5 * glib.time.duration.MilliSecond);
            try grt.std.testing.expect(detector.nextAction() == null);
        }
        fn testQueueOverflowAfterWrapPreservesFifoOrder() !void {
            var detector = Detector.initDefault();

            detector.queueAction(.{ .shake = .{ .magnitude = 1.0, .duration = 1 * glib.time.duration.MilliSecond } });
            detector.queueAction(.{ .shake = .{ .magnitude = 2.0, .duration = 2 * glib.time.duration.MilliSecond } });
            detector.queueAction(.{ .shake = .{ .magnitude = 3.0, .duration = 3 * glib.time.duration.MilliSecond } });
            detector.queueAction(.{ .shake = .{ .magnitude = 4.0, .duration = 4 * glib.time.duration.MilliSecond } });

            try expectShakeDuration(detector.nextAction().?, 1 * glib.time.duration.MilliSecond);

            detector.queueAction(.{ .shake = .{ .magnitude = 5.0, .duration = 5 * glib.time.duration.MilliSecond } });
            detector.queueAction(.{ .shake = .{ .magnitude = 6.0, .duration = 6 * glib.time.duration.MilliSecond } });

            try grt.std.testing.expectEqual(@as(usize, action_queue_capacity), detector.count);
            try expectShakeDuration(detector.nextAction().?, 3 * glib.time.duration.MilliSecond);
            try expectShakeDuration(detector.nextAction().?, 4 * glib.time.duration.MilliSecond);
            try expectShakeDuration(detector.nextAction().?, 5 * glib.time.duration.MilliSecond);
            try expectShakeDuration(detector.nextAction().?, 6 * glib.time.duration.MilliSecond);
            try grt.std.testing.expect(detector.nextAction() == null);
        }
        fn expectShakeDuration(action: Action, expected_duration: glib.time.duration.Duration) !void {
            switch (action) {
                .shake => |shake| try grt.std.testing.expectEqual(expected_duration, shake.duration),
                else => try grt.std.testing.expect(false),
            }
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.testFirstSampleOnlySeedsBaseline() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testShakeEmitsAfterActivityReturnsQuiet() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testTiltEmitsAbsoluteAngles() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testTiltDebounceBlocksRapidRepeat() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testSpeakerLikeSmallVibrationStaysQuiet() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testSlowReorientationDoesNotLookLikeShake() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testHumanShakeStillWinsAfterSmallVibrationNoise() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testTiltCanFireAgainAfterDebounceWindow() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testFlipNeedsRecentTurnAndFaceChange() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testFreeFallNeedsSustainedLowMagnitude() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testQueueOverflowDropsOldestAction() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testQueueOverflowAfterWrapPreservesFifoOrder() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
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
