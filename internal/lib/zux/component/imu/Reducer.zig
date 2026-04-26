const glib = @import("glib");
const motion = @import("motion");

const Context = @import("../../event/Context.zig");
const imu_event = @import("event.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const Node = @import("../../pipeline/Node.zig");
const State = @import("state.zig");

const Reducer = @This();

allocator: glib.std.mem.Allocator,
detectors: glib.std.AutoHashMap(u32, motion.GestureDetector),
thresholds: motion.Thresholds,
out: ?Emitter = null,

pub fn init(
    allocator: glib.std.mem.Allocator,
    thresholds: motion.Thresholds,
) Reducer {
    return .{
        .allocator = allocator,
        .detectors = glib.std.AutoHashMap(u32, motion.GestureDetector).init(allocator),
        .thresholds = thresholds,
        .out = null,
    };
}

pub fn initDefault(allocator: glib.std.mem.Allocator) Reducer {
    return init(allocator, motion.Thresholds.default);
}

pub fn node(self: *Reducer) Node {
    return Node.init(Reducer, self);
}

pub fn deinit(self: *Reducer) void {
    self.detectors.deinit();
}

pub fn bindOutput(self: *Reducer, out: Emitter) void {
    self.out = out;
}

pub fn process(self: *Reducer, message: Message) !usize {
    return switch (message.body) {
        .raw_imu_accel => |accel| self.processAccel(message, accel),
        .raw_imu_gyro => |gyro| self.processGyro(message, gyro),
        else => self.forward(message),
    };
}

pub fn reduce(store: anytype, message: Message, emit: Emitter) !usize {
    _ = emit;

    switch (message.body) {
        .raw_imu_accel => |accel| {
            const current_state = store.get();
            if (current_state.source_id == accel.source_id and
                current_state.motion != null)
            {
                store.set(State{
                    .source_id = accel.source_id,
                    .motion = null,
                });
            }
            return 0;
        },
        .imu_motion => |imu_motion| {
            store.set(State{
                .source_id = imu_motion.source_id,
                .motion = motionKind(imu_motion.motion),
            });
            return 0;
        },
        else => return 0,
    }
}

fn processAccel(
    self: *Reducer,
    message: Message,
    accel: imu_event.Accel,
) !usize {
    var emitted = try self.forward(message);

    const gop = try self.detectors.getOrPut(accel.source_id);
    if (!gop.found_existing) {
        gop.value_ptr.* = motion.GestureDetector.init(self.thresholds);
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

fn processGyro(
    self: *Reducer,
    message: Message,
    gyro: imu_event.Gyro,
) !usize {
    var emitted = try self.forward(message);

    const gop = try self.detectors.getOrPut(gyro.source_id);
    if (!gop.found_existing) {
        gop.value_ptr.* = motion.GestureDetector.init(self.thresholds);
    }

    const sample: motion.GyroSample = .{
        .gyro = .{
            .x = gyro.x,
            .y = gyro.y,
            .z = gyro.z,
        },
        .timestamp_ms = timestampMs(message.timestamp_ns),
    };

    if (gop.value_ptr.updateGyro(sample)) |action| {
        emitted += try self.emitMotion(message.timestamp_ns, gyro.source_id, action, gyro.ctx);
    }
    while (gop.value_ptr.nextAction()) |action| {
        emitted += try self.emitMotion(message.timestamp_ns, gyro.source_id, action, gyro.ctx);
    }

    return emitted;
}

fn emitMotion(
    self: *Reducer,
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

fn forward(self: *Reducer, message: Message) !usize {
    if (self.out) |out| {
        try out.emit(message);
        return 1;
    }
    return 0;
}

fn timestampMs(timestamp_ns: i128) u64 {
    if (timestamp_ns <= 0) return 0;

    const ns_per_ms: i128 = glib.std.time.ns_per_ms;
    const timestamp_ms = @divTrunc(timestamp_ns, ns_per_ms);
    const max_u64_ms: i128 = @intCast(glib.std.math.maxInt(u64));
    if (timestamp_ms >= max_u64_ms) return glib.std.math.maxInt(u64);
    return @intCast(timestamp_ms);
}

fn motionKind(action: motion.Action) State.Motion {
    return switch (action) {
        .shake => .shake,
        .tilt => .tilt,
        .flip => .flip,
        .free_fall => .free_fall,
    };
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn forwardsRawAccelAndEmitsShake(testing: anytype) !void {
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

            var detector_impl = Reducer.init(testing.allocator, .{
                .shake_threshold_g = 1.0,
                .shake_min_duration_ms = 50,
                .shake_max_duration_ms = 500,
                .tilt_threshold_deg = 9999,
            });
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
            detector.bindOutput(Emitter.init(&collector));

            inline for ([_]struct { ts: i128, x: f32, y: f32, z: f32 }{
                .{ .ts = 0, .x = 0, .y = 0, .z = 1.0 },
                .{ .ts = 10 * lib.time.ns_per_ms, .x = 2.0, .y = 0, .z = 1.0 },
                .{ .ts = 20 * lib.time.ns_per_ms, .x = -2.0, .y = 0, .z = 1.0 },
                .{ .ts = 30 * lib.time.ns_per_ms, .x = 2.0, .y = 0, .z = 1.0 },
                .{ .ts = 80 * lib.time.ns_per_ms, .x = 0, .y = 0, .z = 1.0 },
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
                .timestamp_ns = 140 * lib.time.ns_per_ms,
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

        fn forwardsUnrelatedMessagesUnchanged(testing: anytype) !void {
            const Collector = struct {
                saw_tick: bool = false,

                pub fn emit(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .tick => self.saw_tick = true,
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl = Reducer.initDefault(testing.allocator);
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
            detector.bindOutput(Emitter.init(&collector));

            try testing.expectEqual(@as(usize, 1), try detector.process(.{
                .origin = .timer,
                .timestamp_ns = 99,
                .body = .{ .tick = .{} },
            }));
            try testing.expect(collector.saw_tick);
        }

        fn perSourceDetectorsAreIsolated(testing: anytype) !void {
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

            var detector_impl = Reducer.init(testing.allocator, .{
                .shake_threshold_g = 1.0,
                .shake_min_duration_ms = 50,
                .shake_max_duration_ms = 500,
                .tilt_threshold_deg = 9999,
            });
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
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
                    .timestamp_ns = sample.ts_ms * lib.time.ns_per_ms,
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

        fn speakerLikeVibrationOnlyForwardsRawSamples(testing: anytype) !void {
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

            var detector_impl = Reducer.init(testing.allocator, .{
                .shake_threshold_g = 1.0,
                .shake_min_duration_ms = 50,
                .shake_max_duration_ms = 500,
                .tilt_threshold_deg = 9999,
            });
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
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
                    .timestamp_ns = sample.ts_ms * lib.time.ns_per_ms,
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
        fn forwardsRawGyroAndEmitsFlipAfterFaceChange(testing: anytype) !void {
            const Collector = struct {
                raw_accel_count: usize = 0,
                raw_gyro_count: usize = 0,
                motion_count: usize = 0,
                last_motion: ?motion.Action = null,

                pub fn emit(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .raw_imu_accel => self.raw_accel_count += 1,
                        .raw_imu_gyro => self.raw_gyro_count += 1,
                        .imu_motion => |imu_motion| {
                            self.motion_count += 1;
                            self.last_motion = imu_motion.motion;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl = Reducer.init(testing.allocator, .{
                .shake_threshold_g = 9999,
                .tilt_threshold_deg = 9999,
                .flip_gyro_threshold_dps = 90.0,
                .flip_recent_turn_ms = 400,
                .flip_debounce_ms = 0,
            });
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
            detector.bindOutput(Emitter.init(&collector));

            _ = try detector.process(.{
                .origin = .source,
                .timestamp_ns = 0,
                .body = .{
                    .raw_imu_accel = .{
                        .source_id = 5,
                        .x = 0,
                        .y = 0,
                        .z = 1.0,
                    },
                },
            });
            _ = try detector.process(.{
                .origin = .source,
                .timestamp_ns = 220 * lib.time.ns_per_ms,
                .body = .{
                    .raw_imu_gyro = .{
                        .source_id = 5,
                        .x = 0,
                        .y = 0,
                        .z = 140.0,
                    },
                },
            });
            _ = try detector.process(.{
                .origin = .source,
                .timestamp_ns = 260 * lib.time.ns_per_ms,
                .body = .{
                    .raw_imu_accel = .{
                        .source_id = 5,
                        .x = 0,
                        .y = 0,
                        .z = -1.0,
                    },
                },
            });

            try testing.expectEqual(@as(usize, 2), collector.raw_accel_count);
            try testing.expectEqual(@as(usize, 1), collector.raw_gyro_count);
            try testing.expectEqual(@as(usize, 1), collector.motion_count);
            switch (collector.last_motion.?) {
                .flip => |flip| {
                    try testing.expectEqual(motion.Face.up, flip.from);
                    try testing.expectEqual(motion.Face.down, flip.to);
                },
                else => try testing.expect(false),
            }
        }
        fn rawAccelClearsTransientMotionState(testing: anytype) !void {
            const FakeStore = struct {
                value: State = .{},

                pub fn get(self: *@This()) State {
                    return self.value;
                }

                pub fn set(self: *@This(), next: State) void {
                    self.value = next;
                }
            };

            inline for ([_]State.Motion{ .shake, .tilt, .flip, .free_fall }) |motion_kind| {
                var store = FakeStore{
                    .value = .{
                        .source_id = 17,
                        .motion = motion_kind,
                    },
                };

                _ = try Reducer.reduce(&store, .{
                    .origin = .source,
                    .timestamp_ns = 0,
                    .body = .{
                        .raw_imu_accel = .{
                            .source_id = 17,
                            .x = 0,
                            .y = 0,
                            .z = 1.0,
                        },
                    },
                }, undefined);

                try testing.expectEqual(@as(u32, 17), store.value.source_id);
                try testing.expect(store.value.motion == null);
            }
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            TestCase.forwardsRawAccelAndEmitsShake(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.forwardsUnrelatedMessagesUnchanged(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.perSourceDetectorsAreIsolated(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.speakerLikeVibrationOnlyForwardsRawSamples(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.forwardsRawGyroAndEmitsFlipAfterFaceChange(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rawAccelClearsTransientMotionState(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
