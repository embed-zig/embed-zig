const embed = @import("embed");
const motion = @import("motion");

const Context = @import("../event/Context.zig");
const Emitter = @import("../pipeline/Emitter.zig");
const Message = @import("../pipeline/Message.zig");
const Node = @import("../pipeline/Node.zig");

const MotionDetector = @This();

pub const Event = struct {
    pub const kind = .imu_motion;

    source_id: u32,
    motion: motion.Action,
    ctx: Context.Type = null,
};

allocator: embed.mem.Allocator,
detectors: embed.AutoHashMap(u32, motion.Detector),
thresholds: motion.Thresholds,
out: ?Emitter = null,

pub fn init(
    self: *MotionDetector,
    allocator: embed.mem.Allocator,
    thresholds: motion.Thresholds,
) Node {
    self.* = .{
        .allocator = allocator,
        .detectors = embed.AutoHashMap(u32, motion.Detector).init(allocator),
        .thresholds = thresholds,
        .out = null,
    };
    return Node.init(MotionDetector, self);
}

pub fn initDefault(self: *MotionDetector, allocator: embed.mem.Allocator) Node {
    return self.init(allocator, motion.Thresholds.default);
}

pub fn deinit(self: *MotionDetector) void {
    self.detectors.deinit();
}

pub fn bindOutput(self: *MotionDetector, out: Emitter) void {
    self.out = out;
}

pub fn process(self: *MotionDetector, message: Message) !usize {
    return switch (message.body) {
        .raw_imu_accel => |accel| self.processAccel(message, accel),
        else => self.forward(message),
    };
}

fn processAccel(
    self: *MotionDetector,
    message: Message,
    accel: @import("Accel.zig").Event,
) !usize {
    var emitted = try self.forward(message);

    const gop = try self.detectors.getOrPut(accel.source_id);
    if (!gop.found_existing) {
        gop.value_ptr.* = motion.Detector.init(self.thresholds);
    }

    const sample: motion.Sample = .{
        .accel = .{
            .x = accel.x,
            .y = accel.y,
            .z = accel.z,
        },
        .timestamp_ms = timestampMs(message.timestamp_ns),
    };

    if (gop.value_ptr.update(sample)) |action| {
        emitted += try self.emitMotion(message.timestamp_ns, accel.source_id, action, accel.ctx);
    }
    while (gop.value_ptr.nextAction()) |action| {
        emitted += try self.emitMotion(message.timestamp_ns, accel.source_id, action, accel.ctx);
    }

    return emitted;
}

fn emitMotion(
    self: *MotionDetector,
    timestamp_ns: i128,
    source_id: u32,
    action: motion.Action,
    ctx: Context.Type,
) !usize {
    if (self.out) |out| {
        try out.emit(.{
            .origin = .node,
            .timestamp_ns = timestamp_ns,
            .body = .{
                .imu_motion = .{
                    .source_id = source_id,
                    .motion = action,
                    .ctx = ctx,
                },
            },
        });
        return 1;
    }
    return 0;
}

fn forward(self: *MotionDetector, message: Message) !usize {
    if (self.out) |out| {
        try out.emit(message);
        return 1;
    }
    return 0;
}

fn timestampMs(timestamp_ns: i128) u64 {
    if (timestamp_ns <= 0) return 0;

    const ns_per_ms: i128 = embed.time.ns_per_ms;
    const timestamp_ms = @divTrunc(timestamp_ns, ns_per_ms);
    const max_u64_ms: i128 = @intCast(embed.math.maxInt(u64));
    if (timestamp_ms >= max_u64_ms) return embed.math.maxInt(u64);
    return @intCast(timestamp_ms);
}

test "zux/imu/MotionDetector/unit_tests/forwards_raw_accel_and_emits_shake" {
    const embed_std = @import("embed_std");
    const testing = embed_std.std.testing;

    const Collector = struct {
        raw_count: usize = 0,
        motion_count: usize = 0,
        last_motion: ?motion.Action = null,
        last_source_id: u32 = 0,

        pub fn emit(self: *@This(), message: Message) !void {
            switch (message.body) {
                .raw_imu_accel => self.raw_count += 1,
                .imu_motion => |imu_motion| {
                    self.motion_count += 1;
                    self.last_motion = imu_motion.motion;
                    self.last_source_id = imu_motion.source_id;
                },
                else => return error.UnexpectedMessage,
            }
        }
    };

    var detector_impl: MotionDetector = undefined;
    defer detector_impl.deinit();
    var collector = Collector{};
    var detector = detector_impl.init(testing.allocator, .{
        .shake_threshold_g = 1.0,
        .shake_min_duration_ms = 50,
        .shake_max_duration_ms = 500,
        .tilt_threshold_deg = 9999,
    });
    detector.bindOutput(Emitter.init(&collector));

    inline for ([_]struct { ts: i128, x: f32, y: f32, z: f32 }{
        .{ .ts = 0, .x = 0, .y = 0, .z = 1.0 },
        .{ .ts = 10 * embed.time.ns_per_ms, .x = 2.0, .y = 0, .z = 1.0 },
        .{ .ts = 20 * embed.time.ns_per_ms, .x = -2.0, .y = 0, .z = 1.0 },
        .{ .ts = 30 * embed.time.ns_per_ms, .x = 2.0, .y = 0, .z = 1.0 },
        .{ .ts = 80 * embed.time.ns_per_ms, .x = 0, .y = 0, .z = 1.0 },
    }) |sample| {
        _ = try detector.process(.{
            .origin = .source,
            .timestamp_ns = sample.ts,
            .body = .{
                .raw_imu_accel = .{
                    .source_id = 7,
                    .x = sample.x,
                    .y = sample.y,
                    .z = sample.z,
                },
            },
        });
    }

    try testing.expectEqual(@as(usize, 5), collector.raw_count);
    try testing.expectEqual(@as(usize, 0), collector.motion_count);

    _ = try detector.process(.{
        .origin = .source,
        .timestamp_ns = 140 * embed.time.ns_per_ms,
        .body = .{
            .raw_imu_accel = .{
                .source_id = 7,
                .x = 0,
                .y = 0,
                .z = 1.0,
            },
        },
    });

    try testing.expectEqual(@as(usize, 6), collector.raw_count);
    try testing.expectEqual(@as(usize, 1), collector.motion_count);
    try testing.expectEqual(@as(u32, 7), collector.last_source_id);
    switch (collector.last_motion.?) {
        .shake => |shake| try testing.expect(shake.magnitude >= 1.0),
        else => try testing.expect(false),
    }
}

test "zux/imu/MotionDetector/unit_tests/forwards_unrelated_messages_unchanged" {
    const embed_std = @import("embed_std");
    const testing = embed_std.std.testing;

    const Collector = struct {
        saw_tick: bool = false,

        pub fn emit(self: *@This(), message: Message) !void {
            switch (message.body) {
                .tick => self.saw_tick = true,
                else => return error.UnexpectedMessage,
            }
        }
    };

    var detector_impl: MotionDetector = undefined;
    defer detector_impl.deinit();
    var collector = Collector{};
    var detector = detector_impl.initDefault(testing.allocator);
    detector.bindOutput(Emitter.init(&collector));

    try testing.expectEqual(@as(usize, 1), try detector.process(.{
        .origin = .timer,
        .timestamp_ns = 99,
        .body = .{ .tick = .{} },
    }));
    try testing.expect(collector.saw_tick);
}

test "zux/imu/MotionDetector/unit_tests/per_source_detectors_are_isolated" {
    const embed_std = @import("embed_std");
    const testing = embed_std.std.testing;

    const Collector = struct {
        motion_source_ids: [4]u32 = [_]u32{0} ** 4,
        motion_count: usize = 0,

        pub fn emit(self: *@This(), message: Message) !void {
            switch (message.body) {
                .raw_imu_accel => {},
                .imu_motion => |imu_motion| {
                    self.motion_source_ids[self.motion_count] = imu_motion.source_id;
                    self.motion_count += 1;
                },
                else => return error.UnexpectedMessage,
            }
        }
    };

    var detector_impl: MotionDetector = undefined;
    defer detector_impl.deinit();
    var collector = Collector{};
    var detector = detector_impl.init(testing.allocator, .{
        .shake_threshold_g = 1.0,
        .shake_min_duration_ms = 50,
        .shake_max_duration_ms = 500,
        .tilt_threshold_deg = 9999,
    });
    detector.bindOutput(Emitter.init(&collector));

    inline for ([_]struct { source_id: u32, ts_ms: i128, x: f32 }{
        .{ .source_id = 1, .ts_ms = 0, .x = 0 },
        .{ .source_id = 2, .ts_ms = 0, .x = 0 },
        .{ .source_id = 1, .ts_ms = 10, .x = 2.0 },
        .{ .source_id = 1, .ts_ms = 20, .x = -2.0 },
        .{ .source_id = 1, .ts_ms = 30, .x = 2.0 },
        .{ .source_id = 1, .ts_ms = 80, .x = 0 },
        .{ .source_id = 2, .ts_ms = 80, .x = 0 },
        .{ .source_id = 1, .ts_ms = 140, .x = 0 },
    }) |sample| {
        _ = try detector.process(.{
            .origin = .source,
            .timestamp_ns = sample.ts_ms * embed.time.ns_per_ms,
            .body = .{
                .raw_imu_accel = .{
                    .source_id = sample.source_id,
                    .x = sample.x,
                    .y = 0,
                    .z = 1.0,
                },
            },
        });
    }

    try testing.expectEqual(@as(usize, 1), collector.motion_count);
    try testing.expectEqual(@as(u32, 1), collector.motion_source_ids[0]);
}

test "zux/imu/MotionDetector/unit_tests/speaker_like_vibration_only_forwards_raw_samples" {
    const embed_std = @import("embed_std");
    const testing = embed_std.std.testing;

    const Collector = struct {
        raw_count: usize = 0,
        motion_count: usize = 0,

        pub fn emit(self: *@This(), message: Message) !void {
            switch (message.body) {
                .raw_imu_accel => self.raw_count += 1,
                .imu_motion => self.motion_count += 1,
                else => return error.UnexpectedMessage,
            }
        }
    };

    var detector_impl: MotionDetector = undefined;
    defer detector_impl.deinit();
    var collector = Collector{};
    var detector = detector_impl.init(testing.allocator, .{
        .shake_threshold_g = 1.0,
        .shake_min_duration_ms = 50,
        .shake_max_duration_ms = 500,
        .tilt_threshold_deg = 9999,
    });
    detector.bindOutput(Emitter.init(&collector));

    inline for ([_]struct { ts_ms: i128, x: f32 }{
        .{ .ts_ms = 0, .x = 0.0 },
        .{ .ts_ms = 10, .x = 0.30 },
        .{ .ts_ms = 20, .x = 0.00 },
        .{ .ts_ms = 30, .x = 0.30 },
        .{ .ts_ms = 40, .x = 0.00 },
        .{ .ts_ms = 50, .x = 0.30 },
        .{ .ts_ms = 60, .x = 0.00 },
        .{ .ts_ms = 120, .x = 0.00 },
        .{ .ts_ms = 180, .x = 0.00 },
    }) |sample| {
        _ = try detector.process(.{
            .origin = .source,
            .timestamp_ns = sample.ts_ms * embed.time.ns_per_ms,
            .body = .{
                .raw_imu_accel = .{
                    .source_id = 9,
                    .x = sample.x,
                    .y = 0,
                    .z = 1.0,
                },
            },
        });
    }

    try testing.expectEqual(@as(usize, 9), collector.raw_count);
    try testing.expectEqual(@as(usize, 0), collector.motion_count);
}
