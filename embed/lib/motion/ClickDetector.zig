const glib = @import("glib");

const ClickDetector = @This();

const action_queue_capacity: usize = 4;

pub const Context = ?*anyopaque;

pub const Gesture = union(enum) {
    click: u16,
    long_press: glib.time.duration.Duration,
};

pub const Action = struct {
    gesture: Gesture,
    ctx: Context,
};

pub const Sample = struct {
    timestamp: glib.time.instant.Time,
    pressed: bool,
    ctx: Context = null,
};

pub const Config = struct {
    long_press: glib.time.duration.Duration = default_long_press,
    multi_click_window: glib.time.duration.Duration = default_multi_click_window,
};

const PendingPress = struct {
    pressed_at: glib.time.instant.Time,
    last_long_press: glib.time.duration.Duration = 0,
    ctx: Context,
};

const PendingClicks = struct {
    last_click_at: glib.time.instant.Time,
    count: u16,
    ctx: Context,
};

pub const default_long_press: glib.time.duration.Duration = 500 * glib.time.duration.MilliSecond;
pub const default_multi_click_window: glib.time.duration.Duration = 300 * glib.time.duration.MilliSecond;

pending_press: ?PendingPress = null,
pending_clicks: ?PendingClicks = null,
actions: [action_queue_capacity]?Action = [_]?Action{null} ** action_queue_capacity,
read_idx: usize = 0,
count: usize = 0,
long_press: glib.time.duration.Duration = default_long_press,
multi_click_window: glib.time.duration.Duration = default_multi_click_window,

pub fn init(config: Config) ClickDetector {
    return .{
        .long_press = config.long_press,
        .multi_click_window = config.multi_click_window,
    };
}

pub fn initDefault() ClickDetector {
    return init(.{});
}

pub fn reset(self: *ClickDetector) void {
    self.pending_press = null;
    self.pending_clicks = null;
    self.actions = [_]?Action{null} ** action_queue_capacity;
    self.read_idx = 0;
    self.count = 0;
}

pub fn update(self: *ClickDetector, sample: Sample) ?Action {
    self.flushDue(sample.timestamp);

    if (sample.pressed) {
        if (self.pending_press == null) {
            self.pending_press = .{
                .pressed_at = sample.timestamp,
                .ctx = sample.ctx,
            };
        }
        return self.nextAction();
    }

    const pending_press = self.pending_press orelse return self.nextAction();
    self.pending_press = null;

    const held = elapsed(pending_press.pressed_at, sample.timestamp);
    if (held >= self.long_press) {
        self.pending_clicks = null;
        if (held > pending_press.last_long_press) {
            self.queueAction(.{
                .gesture = .{ .long_press = held },
                .ctx = pending_press.ctx,
            });
        }
        return self.nextAction();
    }

    if (self.pending_clicks) |*pending_clicks| {
        if (elapsed(pending_clicks.last_click_at, sample.timestamp) < self.multi_click_window) {
            const next_count = @addWithOverflow(pending_clicks.count, 1);
            if (next_count[1] == 0) {
                pending_clicks.count = next_count[0];
            }
            pending_clicks.last_click_at = sample.timestamp;
            pending_clicks.ctx = sample.ctx;
            return self.nextAction();
        }
    }

    self.pending_clicks = .{
        .last_click_at = sample.timestamp,
        .count = 1,
        .ctx = sample.ctx,
    };
    return self.nextAction();
}

pub fn flush(self: *ClickDetector, timestamp: glib.time.instant.Time) ?Action {
    self.flushDue(timestamp);
    return self.nextAction();
}

pub fn nextAction(self: *ClickDetector) ?Action {
    if (self.count == 0) return null;

    const idx = self.read_idx;
    const action = self.actions[idx];
    self.actions[idx] = null;
    self.read_idx = (self.read_idx + 1) % action_queue_capacity;
    self.count -= 1;
    return action;
}

pub fn hasPendingActions(self: *const ClickDetector) bool {
    return self.count != 0;
}

fn flushDue(self: *ClickDetector, timestamp: glib.time.instant.Time) void {
    if (self.pending_press) |*pending_press| {
        const held = elapsed(pending_press.pressed_at, timestamp);
        if (held >= self.long_press and held > pending_press.last_long_press) {
            self.pending_clicks = null;
            pending_press.last_long_press = held;
            self.queueAction(.{
                .gesture = .{ .long_press = held },
                .ctx = pending_press.ctx,
            });
        }
    }

    if (self.pending_clicks) |pending_clicks| {
        const quiet = elapsed(pending_clicks.last_click_at, timestamp);
        if (quiet >= self.multi_click_window) {
            self.pending_clicks = null;
            self.queueAction(.{
                .gesture = .{ .click = pending_clicks.count },
                .ctx = pending_clicks.ctx,
            });
        }
    }
}

fn queueAction(self: *ClickDetector, action: Action) void {
    const idx = (self.read_idx + self.count) % action_queue_capacity;
    self.actions[idx] = action;
    if (self.count >= action_queue_capacity) {
        self.read_idx = (self.read_idx + 1) % action_queue_capacity;
        return;
    }
    self.count += 1;
}

fn elapsed(start: glib.time.instant.Time, end: glib.time.instant.Time) glib.time.duration.Duration {
    const duration = glib.time.instant.sub(end, start);
    return if (duration <= 0) 0 else duration;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn testClickEmitsAfterQuietWindow() !void {
            var press_ctx_value: u8 = 1;
            var release_ctx_value: u8 = 2;
            var detector = ClickDetector.initDefault();

            try grt.std.testing.expect(detector.update(.{
                .timestamp = 10,
                .pressed = true,
                .ctx = @ptrCast(&press_ctx_value),
            }) == null);
            try grt.std.testing.expect(detector.update(.{
                .timestamp = 20,
                .pressed = false,
                .ctx = @ptrCast(&release_ctx_value),
            }) == null);

            const action = detector.flush(glib.time.instant.add(20, default_multi_click_window)).?;
            switch (action.gesture) {
                .click => |count| try grt.std.testing.expectEqual(@as(u16, 1), count),
                else => try grt.std.testing.expect(false),
            }
            try grt.std.testing.expect(action.ctx == @as(Context, @ptrCast(&release_ctx_value)));
        }

        fn testMultiClickAccumulatesWithinWindow() !void {
            var last_ctx_value: u8 = 3;
            var detector = ClickDetector.initDefault();

            inline for ([_]glib.time.instant.Time{ 10, 30, 50, 70 }) |start| {
                try grt.std.testing.expect(detector.update(.{
                    .timestamp = start,
                    .pressed = true,
                }) == null);
                try grt.std.testing.expect(detector.update(.{
                    .timestamp = glib.time.instant.add(start, 10),
                    .pressed = false,
                    .ctx = @ptrCast(&last_ctx_value),
                }) == null);
            }

            const action = detector.flush(glib.time.instant.add(80, default_multi_click_window)).?;
            switch (action.gesture) {
                .click => |count| try grt.std.testing.expectEqual(@as(u16, 4), count),
                else => try grt.std.testing.expect(false),
            }
            try grt.std.testing.expect(action.ctx == @as(Context, @ptrCast(&last_ctx_value)));
        }

        fn testLongPressEmitsOnFlush() !void {
            var press_ctx_value: u8 = 4;
            var detector = ClickDetector.initDefault();

            try grt.std.testing.expect(detector.update(.{
                .timestamp = 10,
                .pressed = true,
                .ctx = @ptrCast(&press_ctx_value),
            }) == null);

            const action = detector.flush(glib.time.instant.add(10, default_long_press + 25)).?;
            try expectLongPressDuration(action, default_long_press + 25);
            try grt.std.testing.expect(action.ctx == @as(Context, @ptrCast(&press_ctx_value)));
        }

        fn testReleaseAfterFlushedLongPressEmitsUpdatedDuration() !void {
            var detector = ClickDetector.initDefault();
            _ = detector.update(.{
                .timestamp = 10,
                .pressed = true,
            });
            const first_action = detector.flush(glib.time.instant.add(10, default_long_press + 1)).?;
            try expectLongPressDuration(first_action, default_long_press + 1);

            const release_action = detector.update(.{
                .timestamp = glib.time.instant.add(10, default_long_press + 10),
                .pressed = false,
            }).?;
            try expectLongPressDuration(release_action, default_long_press + 10);
            try grt.std.testing.expect(!detector.hasPendingActions());
        }

        fn testHeldSamplesAfterLongPressEmitCumulativeDuration() !void {
            var detector = ClickDetector.initDefault();
            try grt.std.testing.expect(detector.update(.{
                .timestamp = 10,
                .pressed = true,
            }) == null);

            const first_action = detector.flush(glib.time.instant.add(10, default_long_press + 1)).?;
            try expectLongPressDuration(first_action, default_long_press + 1);

            const second_action = detector.update(.{
                .timestamp = glib.time.instant.add(10, default_long_press + 50),
                .pressed = true,
            }).?;
            try expectLongPressDuration(second_action, default_long_press + 50);

            const third_action = detector.flush(glib.time.instant.add(10, default_long_press * 2 + 50)).?;
            try expectLongPressDuration(third_action, default_long_press * 2 + 50);

            try grt.std.testing.expect(detector.update(.{
                .timestamp = glib.time.instant.add(10, default_long_press * 2 + 50),
                .pressed = false,
            }) == null);
            try grt.std.testing.expect(!detector.hasPendingActions());
        }

        fn testReleaseAtSameTimestampDoesNotDuplicateLongPress() !void {
            var detector = ClickDetector.initDefault();
            try grt.std.testing.expect(detector.update(.{
                .timestamp = 10,
                .pressed = true,
            }) == null);

            const release_at = glib.time.instant.add(10, default_long_press + 20);
            const first_action = detector.flush(release_at).?;
            try expectLongPressDuration(first_action, default_long_press + 20);

            try grt.std.testing.expect(detector.update(.{
                .timestamp = release_at,
                .pressed = false,
            }) == null);
        }

        fn testQueueOverflowDropsOldestAction() !void {
            var detector = ClickDetector.initDefault();

            detector.queueAction(.{ .gesture = .{ .click = 1 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 2 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 3 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 4 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 5 }, .ctx = null });

            try grt.std.testing.expectEqual(@as(usize, action_queue_capacity), detector.count);
            try expectClickCount(detector.nextAction().?, 2);
            try expectClickCount(detector.nextAction().?, 3);
            try expectClickCount(detector.nextAction().?, 4);
            try expectClickCount(detector.nextAction().?, 5);
            try grt.std.testing.expect(detector.nextAction() == null);
        }

        fn testQueueOverflowAfterWrapPreservesFifoOrder() !void {
            var detector = ClickDetector.initDefault();

            detector.queueAction(.{ .gesture = .{ .click = 1 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 2 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 3 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 4 }, .ctx = null });

            try expectClickCount(detector.nextAction().?, 1);

            detector.queueAction(.{ .gesture = .{ .click = 5 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 6 }, .ctx = null });

            try grt.std.testing.expectEqual(@as(usize, action_queue_capacity), detector.count);
            try expectClickCount(detector.nextAction().?, 3);
            try expectClickCount(detector.nextAction().?, 4);
            try expectClickCount(detector.nextAction().?, 5);
            try expectClickCount(detector.nextAction().?, 6);
            try grt.std.testing.expect(detector.nextAction() == null);
        }

        fn expectClickCount(action: Action, expected_count: u16) !void {
            switch (action.gesture) {
                .click => |count| try grt.std.testing.expectEqual(expected_count, count),
                else => try grt.std.testing.expect(false),
            }
        }

        fn expectLongPressDuration(action: Action, expected_held: glib.time.duration.Duration) !void {
            switch (action.gesture) {
                .long_press => |held| try grt.std.testing.expectEqual(expected_held, held),
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

            TestCase.testClickEmitsAfterQuietWindow() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testMultiClickAccumulatesWithinWindow() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testLongPressEmitsOnFlush() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testReleaseAfterFlushedLongPressEmitsUpdatedDuration() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testHeldSamplesAfterLongPressEmitCumulativeDuration() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testReleaseAtSameTimestampDoesNotDuplicateLongPress() catch |err| {
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
