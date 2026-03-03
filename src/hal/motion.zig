//! Motion Detection HAL Component.
//!
//! 提供板级可复用的运动事件检测：
//! - shake
//! - tap / double-tap
//! - tilt
//! - flip（需要陀螺仪能力）
//! - freefall（需要陀螺仪能力）

const std = @import("std");
const hal_marker = @import("marker.zig");
const imu_mod = @import("imu.zig");

pub const Error = imu_mod.Error;

pub const Axis = enum(u2) {
    x = 0,
    y = 1,
    z = 2,
};

pub const Orientation = enum(u3) {
    face_up = 0,
    face_down = 1,
    portrait = 2,
    portrait_inverted = 3,
    landscape_left = 4,
    landscape_right = 5,
    unknown = 7,
};

pub const MotionEventPayload = struct {
    source: []const u8,
    timestamp_ms: u64,
    action: Action,

    pub const Action = union(enum) {
        shake: struct {
            magnitude: f32,
            duration_ms: u32,
        },
        tap: struct {
            axis: Axis,
            count: u8,
            positive: bool,
        },
        tilt: struct {
            roll: f32,
            pitch: f32,
        },
        flip: struct {
            from: Orientation,
            to: Orientation,
        },
        freefall: struct {
            duration_ms: u32,
        },
    };
};

pub const Thresholds = struct {
    // Shake
    shake_delta_g: f32 = 1.2,
    shake_window_ms: u32 = 450,
    shake_min_pulses: u8 = 3,

    // Tap
    tap_peak_g: f32 = 1.8,
    tap_release_g: f32 = 1.1,
    tap_max_duration_ms: u32 = 130,
    double_tap_window_ms: u32 = 320,

    // Tilt
    tilt_threshold_deg: f32 = 35.0,
    tilt_emit_interval_ms: u32 = 180,

    // Freefall (需要陀螺仪能力才启用)
    freefall_threshold_g: f32 = 0.2,
    freefall_min_duration_ms: u32 = 150,
};

pub const types = struct {
    pub const Thresholds = @import("motion.zig").Thresholds;
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .motion;
}

pub fn from(comptime spec: type) type {
    const has_spec_thresholds = comptime @hasDecl(spec, "thresholds");

    const Driver = comptime blk: {
        if (@hasDecl(spec, "Driver")) break :blk spec.Driver;
        if (@hasDecl(spec, "Imu")) break :blk spec.Imu;
        @compileError("motion spec must define Driver (or legacy Imu)");
    };

    comptime {
        _ = @as(type, Driver);
        _ = @as([]const u8, spec.meta.id);
        if (has_spec_thresholds) {
            _ = @as(Thresholds, spec.thresholds);
        }
    }

    const BaseDriver = comptime switch (@typeInfo(Driver)) {
        .pointer => |p| p.child,
        else => Driver,
    };

    comptime {
        _ = @as(*const fn (*BaseDriver) Error!imu_mod.AccelData, &BaseDriver.readAccel);
        _ = @as(*const fn (*BaseDriver) Error!imu_mod.GyroData, &BaseDriver.readGyro);
    }

    const default_thresholds: Thresholds = if (has_spec_thresholds) spec.thresholds else .{};

    return struct {
        const Self = @This();
        pub const Event = MotionEventPayload;
        pub const EventCallback = *const fn (?*anyopaque, Event) void;

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .motion,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;
        pub const has_gyroscope = true;

        driver: *Driver,
        thresholds: Thresholds = default_thresholds,

        last_accel: ?imu_mod.AccelData = null,
        last_orientation: Orientation = .unknown,

        shake_window_start_ms: ?u64 = null,
        shake_pulses: u8 = 0,

        tap_active: bool = false,
        tap_axis: Axis = .x,
        tap_positive: bool = true,
        tap_start_ms: u64 = 0,
        last_tap_ms: ?u64 = null,

        freefall_start_ms: ?u64 = null,
        freefall_emitted: bool = false,

        last_tilt_emit_ms: u64 = 0,

        queue: [8]Event = undefined,
        q_head: usize = 0,
        q_tail: usize = 0,
        q_len: usize = 0,

        event_callback: ?EventCallback = null,
        event_ctx: ?*anyopaque = null,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn initWithThresholds(driver: *Driver, thresholds: Thresholds) Self {
            return .{ .driver = driver, .thresholds = thresholds };
        }

        pub fn setCallback(self: *Self, callback: EventCallback, ctx: ?*anyopaque) void {
            self.event_callback = callback;
            self.event_ctx = ctx;
        }

        /// 轮询一次传感器，并返回一条事件（若有）。
        ///
        /// 说明：一次 poll 可能产生多条事件，剩余事件可通过 nextEvent() 继续读取。
        pub fn poll(self: *Self, now_ms: u64) Error!?Event {
            const accel = try self.driver.readAccel();
            // 读取 gyro，确保 6DoF 合约路径活跃。
            _ = try self.driver.readGyro();

            self.detect(now_ms, accel);
            self.last_accel = accel;
            return self.nextEvent();
        }

        pub fn nextEvent(self: *Self) ?Event {
            if (self.q_len == 0) return null;
            const ev = self.queue[self.q_head];
            self.q_head = (self.q_head + 1) % self.queue.len;
            self.q_len -= 1;
            return ev;
        }

        pub fn reset(self: *Self) void {
            self.last_accel = null;
            self.last_orientation = .unknown;
            self.shake_window_start_ms = null;
            self.shake_pulses = 0;
            self.tap_active = false;
            self.last_tap_ms = null;
            self.freefall_start_ms = null;
            self.freefall_emitted = false;
            self.last_tilt_emit_ms = 0;
            self.q_head = 0;
            self.q_tail = 0;
            self.q_len = 0;
        }

        pub fn setThresholds(self: *Self, thresholds: Thresholds) void {
            self.thresholds = thresholds;
        }

        pub fn getThresholds(self: *const Self) Thresholds {
            return self.thresholds;
        }

        fn detect(self: *Self, now_ms: u64, accel: imu_mod.AccelData) void {
            self.detectShake(now_ms, accel);
            self.detectTap(now_ms, accel);
            self.detectTilt(now_ms, accel);
            self.detectFlip(now_ms, accel);
            self.detectFreefall(now_ms, accel);
        }

        fn detectShake(self: *Self, now_ms: u64, accel: imu_mod.AccelData) void {
            const prev = self.last_accel orelse return;
            const delta = absf(accel.x - prev.x) + absf(accel.y - prev.y) + absf(accel.z - prev.z);

            if (delta >= self.thresholds.shake_delta_g) {
                if (self.shake_window_start_ms) |start| {
                    if (now_ms > start and now_ms - start <= self.thresholds.shake_window_ms) {
                        self.shake_pulses +|= 1;
                    } else {
                        self.shake_window_start_ms = now_ms;
                        self.shake_pulses = 1;
                    }
                } else {
                    self.shake_window_start_ms = now_ms;
                    self.shake_pulses = 1;
                }

                if (self.shake_window_start_ms) |start| {
                    if (self.shake_pulses >= self.thresholds.shake_min_pulses) {
                        self.pushAction(now_ms, .{ .shake = .{
                            .magnitude = delta,
                            .duration_ms = elapsedMs(now_ms, start),
                        } });
                        self.shake_window_start_ms = null;
                        self.shake_pulses = 0;
                    }
                }
            } else if (self.shake_window_start_ms) |start| {
                if (now_ms > start and now_ms - start > self.thresholds.shake_window_ms) {
                    self.shake_window_start_ms = null;
                    self.shake_pulses = 0;
                }
            }
        }

        fn detectTap(self: *Self, now_ms: u64, accel: imu_mod.AccelData) void {
            const dom = dominantAxis(accel);

            if (!self.tap_active) {
                if (dom.abs_value >= self.thresholds.tap_peak_g) {
                    self.tap_active = true;
                    self.tap_axis = dom.axis;
                    self.tap_positive = dom.value >= 0;
                    self.tap_start_ms = now_ms;
                }
                return;
            }

            if (now_ms > self.tap_start_ms and now_ms - self.tap_start_ms > self.thresholds.tap_max_duration_ms) {
                self.tap_active = false;
                return;
            }

            const release_axis_abs = absf(axisValue(accel, self.tap_axis));
            if (release_axis_abs <= self.thresholds.tap_release_g) {
                var count: u8 = 1;
                if (self.last_tap_ms) |last| {
                    if (now_ms >= last and now_ms - last <= self.thresholds.double_tap_window_ms) {
                        count = 2;
                    }
                }
                self.last_tap_ms = now_ms;
                self.tap_active = false;

                self.pushAction(now_ms, .{ .tap = .{
                    .axis = self.tap_axis,
                    .count = count,
                    .positive = self.tap_positive,
                } });
            }
        }

        fn detectTilt(self: *Self, now_ms: u64, accel: imu_mod.AccelData) void {
            const yz_norm = std.math.sqrt(accel.y * accel.y + accel.z * accel.z);
            const roll = std.math.atan2(accel.y, accel.z) * 180.0 / std.math.pi;
            const pitch = std.math.atan2(-accel.x, yz_norm) * 180.0 / std.math.pi;

            if (absf(roll) < self.thresholds.tilt_threshold_deg and absf(pitch) < self.thresholds.tilt_threshold_deg) {
                return;
            }

            if (self.last_tilt_emit_ms != 0 and now_ms > self.last_tilt_emit_ms and now_ms - self.last_tilt_emit_ms < self.thresholds.tilt_emit_interval_ms) {
                return;
            }

            self.last_tilt_emit_ms = now_ms;
            self.pushAction(now_ms, .{ .tilt = .{ .roll = roll, .pitch = pitch } });
        }

        fn detectFlip(self: *Self, now_ms: u64, accel: imu_mod.AccelData) void {
            const cur = classifyOrientation(accel);
            defer self.last_orientation = cur;
            if (self.last_orientation == .unknown) return;
            if (cur == self.last_orientation) return;

            self.pushAction(now_ms, .{ .flip = .{ .from = self.last_orientation, .to = cur } });
        }

        fn detectFreefall(self: *Self, now_ms: u64, accel: imu_mod.AccelData) void {
            const mag = accelMagnitude(accel);
            if (mag <= self.thresholds.freefall_threshold_g) {
                if (self.freefall_start_ms == null) {
                    self.freefall_start_ms = now_ms;
                    self.freefall_emitted = false;
                    return;
                }

                const start = self.freefall_start_ms.?;
                if (!self.freefall_emitted and now_ms >= start and now_ms - start >= self.thresholds.freefall_min_duration_ms) {
                    self.freefall_emitted = true;
                    self.pushAction(now_ms, .{ .freefall = .{ .duration_ms = elapsedMs(now_ms, start) } });
                }
                return;
            }

            self.freefall_start_ms = null;
            self.freefall_emitted = false;
        }

        fn pushAction(self: *Self, now_ms: u64, action: Event.Action) void {
            const ev: Event = .{
                .source = meta.id,
                .timestamp_ms = now_ms,
                .action = action,
            };

            if (self.event_callback) |cb| {
                cb(self.event_ctx, ev);
                return;
            }

            self.pushEvent(ev);
        }

        fn pushEvent(self: *Self, ev: Event) void {
            if (self.q_len >= self.queue.len) return;
            self.queue[self.q_tail] = ev;
            self.q_tail = (self.q_tail + 1) % self.queue.len;
            self.q_len += 1;
        }

        fn accelMagnitude(accel: imu_mod.AccelData) f32 {
            return std.math.sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z);
        }

        fn classifyOrientation(accel: imu_mod.AccelData) Orientation {
            if (accel.z >= 0.75) return .face_up;
            if (accel.z <= -0.75) return .face_down;

            if (absf(accel.x) > absf(accel.y)) {
                return if (accel.x >= 0) .landscape_right else .landscape_left;
            }
            return if (accel.y >= 0) .portrait else .portrait_inverted;
        }

        const Dominant = struct {
            axis: Axis,
            value: f32,
            abs_value: f32,
        };

        fn dominantAxis(accel: imu_mod.AccelData) Dominant {
            const ax = absf(accel.x);
            const ay = absf(accel.y);
            const az = absf(accel.z);

            if (ax >= ay and ax >= az) {
                return .{ .axis = .x, .value = accel.x, .abs_value = ax };
            }
            if (ay >= ax and ay >= az) {
                return .{ .axis = .y, .value = accel.y, .abs_value = ay };
            }
            return .{ .axis = .z, .value = accel.z, .abs_value = az };
        }

        fn axisValue(accel: imu_mod.AccelData, axis: Axis) f32 {
            return switch (axis) {
                .x => accel.x,
                .y => accel.y,
                .z => accel.z,
            };
        }

        fn absf(v: f32) f32 {
            return if (v < 0) -v else v;
        }

        fn elapsedMs(now: u64, start: u64) u32 {
            const raw = if (now >= start) now - start else 0;
            const capped = @min(raw, std.math.maxInt(u32));
            return @intCast(capped);
        }
    };
}

test "motion marker and shake detection" {
    const MockDriver = struct {
        samples: []const imu_mod.AccelData,
        idx: usize = 0,

        pub fn readAccel(self: *@This()) Error!imu_mod.AccelData {
            const i = @min(self.idx, self.samples.len - 1);
            const out = self.samples[i];
            if (self.idx + 1 < self.samples.len) self.idx += 1;
            return out;
        }
        pub fn readGyro(_: *@This()) Error!imu_mod.GyroData {
            return .{ .x = 0, .y = 0, .z = 0 };
        }
    };

    const Motion = from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "motion.shake" };
        pub const thresholds = Thresholds{
            .shake_delta_g = 1.0,
            .shake_window_ms = 300,
            .shake_min_pulses = 3,
            .tap_peak_g = 10,
            .tilt_threshold_deg = 179,
            .freefall_threshold_g = 0.05,
        };
    });

    try std.testing.expect(is(Motion));
    try std.testing.expect(Motion.has_gyroscope);

    const samples = [_]imu_mod.AccelData{
        .{ .x = 0, .y = 0, .z = 1 },
        .{ .x = 1.5, .y = 0, .z = 1 },
        .{ .x = -1.5, .y = 0, .z = 1 },
        .{ .x = 1.6, .y = 0, .z = 1 },
    };

    var driver = MockDriver{ .samples = &samples };
    var motion = Motion.init(&driver);

    var saw_shake = false;
    const times = [_]u64{ 0, 50, 100, 150 };
    for (times) |t| {
        if (try motion.poll(t)) |ev| {
            switch (ev.action) {
                .shake => saw_shake = true,
                else => {},
            }
        }
    }

    try std.testing.expect(saw_shake);
}

test "motion double tap detection" {
    const MockDriver = struct {
        samples: []const imu_mod.AccelData,
        idx: usize = 0,

        pub fn readAccel(self: *@This()) Error!imu_mod.AccelData {
            const i = @min(self.idx, self.samples.len - 1);
            const out = self.samples[i];
            if (self.idx + 1 < self.samples.len) self.idx += 1;
            return out;
        }
        pub fn readGyro(_: *@This()) Error!imu_mod.GyroData {
            return .{ .x = 0, .y = 0, .z = 0 };
        }
    };

    const Motion = from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "motion.tap" };
        pub const thresholds = Thresholds{
            .shake_delta_g = 99,
            .tap_peak_g = 2.0,
            .tap_release_g = 0.8,
            .tap_max_duration_ms = 120,
            .double_tap_window_ms = 300,
            .tilt_threshold_deg = 179,
        };
    });

    const samples = [_]imu_mod.AccelData{
        .{ .x = 0.0, .y = 0.0, .z = 1.0 },
        .{ .x = 2.3, .y = 0.0, .z = 0.8 },
        .{ .x = 0.1, .y = 0.0, .z = 1.0 },
        .{ .x = 2.4, .y = 0.0, .z = 0.8 },
        .{ .x = 0.1, .y = 0.0, .z = 1.0 },
    };

    var driver = MockDriver{ .samples = &samples };
    var motion = Motion.init(&driver);

    var saw_double_tap = false;
    const times = [_]u64{ 0, 20, 80, 150, 210 };
    for (times) |t| {
        if (try motion.poll(t)) |ev| {
            switch (ev.action) {
                .tap => |tap| {
                    if (tap.count == 2) saw_double_tap = true;
                },
                else => {},
            }
        }
    }

    try std.testing.expect(saw_double_tap);
}

test "motion flip and freefall with gyro capability" {
    const MockDriver = struct {
        samples: []const imu_mod.AccelData,
        idx: usize = 0,

        pub fn readAccel(self: *@This()) Error!imu_mod.AccelData {
            const i = @min(self.idx, self.samples.len - 1);
            const out = self.samples[i];
            if (self.idx + 1 < self.samples.len) self.idx += 1;
            return out;
        }

        pub fn readGyro(_: *@This()) Error!imu_mod.GyroData {
            return .{ .x = 0, .y = 0, .z = 0 };
        }
    };

    const Motion = from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "motion.flip" };
        pub const thresholds = Thresholds{
            .shake_delta_g = 99,
            .tap_peak_g = 99,
            .tilt_threshold_deg = 179,
            .freefall_threshold_g = 0.10,
            .freefall_min_duration_ms = 100,
        };
    });

    try std.testing.expect(Motion.has_gyroscope);

    const samples = [_]imu_mod.AccelData{
        .{ .x = 0, .y = 0, .z = 1.0 },
        .{ .x = 0, .y = 0, .z = -1.0 },
        .{ .x = 0.0, .y = 0.0, .z = 0.05 },
        .{ .x = 0.0, .y = 0.0, .z = 0.04 },
        .{ .x = 0, .y = 0, .z = 1.0 },
    };

    var driver = MockDriver{ .samples = &samples };
    var motion = Motion.init(&driver);

    var has_flip = false;
    var has_freefall = false;

    const times = [_]u64{ 0, 50, 100, 250, 320 };
    for (times) |t| {
        if (try motion.poll(t)) |ev| {
            switch (ev.action) {
                .flip => has_flip = true,
                .freefall => has_freefall = true,
                else => {},
            }
        }
    }

    // 可能还有排队事件，继续取空
    while (motion.nextEvent()) |ev| {
        switch (ev.action) {
            .flip => has_flip = true,
            .freefall => has_freefall = true,
            else => {},
        }
    }

    try std.testing.expect(has_flip);
    try std.testing.expect(has_freefall);
}
