const glib = @import("glib");

const ClickDetector = @This();

const action_queue_capacity: usize = 4;

pub const Context = ?*anyopaque;

pub const Gesture = union(enum) {
    click: u16,
    long_press_ns: u64,
};

pub const Action = struct {
    gesture: Gesture,
    ctx: Context,
};

pub const Sample = struct {
    timestamp_ns: i128,
    pressed: bool,
    ctx: Context = null,
};

pub const Config = struct {
    long_press_ns: u64 = default_long_press_ns,
    multi_click_window_ns: u64 = default_multi_click_window_ns,
};

const PendingPress = struct {
    pressed_at_ns: i128,
    last_long_press_ns: u64 = 0,
    ctx: Context,
};

const PendingClicks = struct {
    last_click_at_ns: i128,
    count: u16,
    ctx: Context,
};

pub const ns_per_ms: u64 = 1_000_000;
pub const default_long_press_ns: u64 = 500 * ns_per_ms;
pub const default_multi_click_window_ns: u64 = 300 * ns_per_ms;

pending_press: ?PendingPress = null,
pending_clicks: ?PendingClicks = null,
actions: [action_queue_capacity]?Action = [_]?Action{null} ** action_queue_capacity,
read_idx: usize = 0,
count: usize = 0,
long_press_ns: u64 = default_long_press_ns,
multi_click_window_ns: u64 = default_multi_click_window_ns,

pub fn init(config: Config) ClickDetector {
    return .{
        .long_press_ns = config.long_press_ns,
        .multi_click_window_ns = config.multi_click_window_ns,
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
    self.flushDue(sample.timestamp_ns);

    if (sample.pressed) {
        if (self.pending_press == null) {
            self.pending_press = .{
                .pressed_at_ns = sample.timestamp_ns,
                .ctx = sample.ctx,
            };
        }
        return self.nextAction();
    }

    const pending_press = self.pending_press orelse return self.nextAction();
    self.pending_press = null;

    const held_ns = elapsedNs(pending_press.pressed_at_ns, sample.timestamp_ns);
    if (held_ns >= self.long_press_ns) {
        self.pending_clicks = null;
        if (held_ns > pending_press.last_long_press_ns) {
            self.queueAction(.{
                .gesture = .{ .long_press_ns = held_ns },
                .ctx = pending_press.ctx,
            });
        }
        return self.nextAction();
    }

    if (self.pending_clicks) |*pending_clicks| {
        if (elapsedNs(pending_clicks.last_click_at_ns, sample.timestamp_ns) < self.multi_click_window_ns) {
            const next_count = @addWithOverflow(pending_clicks.count, 1);
            if (next_count[1] == 0) {
                pending_clicks.count = next_count[0];
            }
            pending_clicks.last_click_at_ns = sample.timestamp_ns;
            pending_clicks.ctx = sample.ctx;
            return self.nextAction();
        }
    }

    self.pending_clicks = .{
        .last_click_at_ns = sample.timestamp_ns,
        .count = 1,
        .ctx = sample.ctx,
    };
    return self.nextAction();
}

pub fn flush(self: *ClickDetector, timestamp_ns: i128) ?Action {
    self.flushDue(timestamp_ns);
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

fn flushDue(self: *ClickDetector, timestamp_ns: i128) void {
    if (self.pending_press) |*pending_press| {
        const held_ns = elapsedNs(pending_press.pressed_at_ns, timestamp_ns);
        if (held_ns >= self.long_press_ns and held_ns > pending_press.last_long_press_ns) {
            self.pending_clicks = null;
            pending_press.last_long_press_ns = held_ns;
            self.queueAction(.{
                .gesture = .{ .long_press_ns = held_ns },
                .ctx = pending_press.ctx,
            });
        }
    }

    if (self.pending_clicks) |pending_clicks| {
        const quiet_ns = elapsedNs(pending_clicks.last_click_at_ns, timestamp_ns);
        if (quiet_ns >= self.multi_click_window_ns) {
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

fn elapsedNs(start_ns: i128, end_ns: i128) u64 {
    if (end_ns <= start_ns) return 0;

    const delta_ns = end_ns - start_ns;
    const max_u64_ns: i128 = 18_446_744_073_709_551_615;
    if (delta_ns >= max_u64_ns) return 18_446_744_073_709_551_615;
    return @intCast(delta_ns);
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn testClickEmitsAfterQuietWindow() !void {
            const testing = lib.testing;

            var press_ctx_value: u8 = 1;
            var release_ctx_value: u8 = 2;
            var detector = ClickDetector.initDefault();

            try testing.expect(detector.update(.{
                .timestamp_ns = 10,
                .pressed = true,
                .ctx = @ptrCast(&press_ctx_value),
            }) == null);
            try testing.expect(detector.update(.{
                .timestamp_ns = 20,
                .pressed = false,
                .ctx = @ptrCast(&release_ctx_value),
            }) == null);

            const action = detector.flush(20 + @as(i128, default_multi_click_window_ns)).?;
            switch (action.gesture) {
                .click => |count| try testing.expectEqual(@as(u16, 1), count),
                else => try testing.expect(false),
            }
            try testing.expect(action.ctx == @as(Context, @ptrCast(&release_ctx_value)));
        }

        fn testMultiClickAccumulatesWithinWindow() !void {
            const testing = lib.testing;

            var last_ctx_value: u8 = 3;
            var detector = ClickDetector.initDefault();

            inline for ([_]i128{ 10, 30, 50, 70 }) |start_ns| {
                try testing.expect(detector.update(.{
                    .timestamp_ns = start_ns,
                    .pressed = true,
                }) == null);
                try testing.expect(detector.update(.{
                    .timestamp_ns = start_ns + 10,
                    .pressed = false,
                    .ctx = @ptrCast(&last_ctx_value),
                }) == null);
            }

            const action = detector.flush(80 + @as(i128, default_multi_click_window_ns)).?;
            switch (action.gesture) {
                .click => |count| try testing.expectEqual(@as(u16, 4), count),
                else => try testing.expect(false),
            }
            try testing.expect(action.ctx == @as(Context, @ptrCast(&last_ctx_value)));
        }

        fn testLongPressEmitsOnFlush() !void {
            const testing = lib.testing;

            var press_ctx_value: u8 = 4;
            var detector = ClickDetector.initDefault();

            try testing.expect(detector.update(.{
                .timestamp_ns = 10,
                .pressed = true,
                .ctx = @ptrCast(&press_ctx_value),
            }) == null);

            const action = detector.flush(10 + @as(i128, default_long_press_ns) + 25).?;
            try expectLongPressDuration(action, default_long_press_ns + 25);
            try testing.expect(action.ctx == @as(Context, @ptrCast(&press_ctx_value)));
        }

        fn testReleaseAfterFlushedLongPressEmitsUpdatedDuration() !void {
            const testing = lib.testing;

            var detector = ClickDetector.initDefault();
            _ = detector.update(.{
                .timestamp_ns = 10,
                .pressed = true,
            });
            const first_action = detector.flush(10 + @as(i128, default_long_press_ns) + 1).?;
            try expectLongPressDuration(first_action, default_long_press_ns + 1);

            const release_action = detector.update(.{
                .timestamp_ns = 10 + @as(i128, default_long_press_ns) + 10,
                .pressed = false,
            }).?;
            try expectLongPressDuration(release_action, default_long_press_ns + 10);
            try testing.expect(!detector.hasPendingActions());
        }

        fn testHeldSamplesAfterLongPressEmitCumulativeDuration() !void {
            const testing = lib.testing;

            var detector = ClickDetector.initDefault();
            try testing.expect(detector.update(.{
                .timestamp_ns = 10,
                .pressed = true,
            }) == null);

            const first_action = detector.flush(10 + @as(i128, default_long_press_ns) + 1).?;
            try expectLongPressDuration(first_action, default_long_press_ns + 1);

            const second_action = detector.update(.{
                .timestamp_ns = 10 + @as(i128, default_long_press_ns) + 50,
                .pressed = true,
            }).?;
            try expectLongPressDuration(second_action, default_long_press_ns + 50);

            const third_action = detector.flush(10 + @as(i128, default_long_press_ns) * 2 + 50).?;
            try expectLongPressDuration(third_action, default_long_press_ns * 2 + 50);

            try testing.expect(detector.update(.{
                .timestamp_ns = 10 + @as(i128, default_long_press_ns) * 2 + 50,
                .pressed = false,
            }) == null);
            try testing.expect(!detector.hasPendingActions());
        }

        fn testReleaseAtSameTimestampDoesNotDuplicateLongPress() !void {
            const testing = lib.testing;

            var detector = ClickDetector.initDefault();
            try testing.expect(detector.update(.{
                .timestamp_ns = 10,
                .pressed = true,
            }) == null);

            const held_ns = 10 + @as(i128, default_long_press_ns) + 20;
            const first_action = detector.flush(held_ns).?;
            try expectLongPressDuration(first_action, default_long_press_ns + 20);

            try testing.expect(detector.update(.{
                .timestamp_ns = held_ns,
                .pressed = false,
            }) == null);
        }

        fn testQueueOverflowDropsOldestAction() !void {
            const testing = lib.testing;

            var detector = ClickDetector.initDefault();

            detector.queueAction(.{ .gesture = .{ .click = 1 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 2 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 3 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 4 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 5 }, .ctx = null });

            try testing.expectEqual(@as(usize, action_queue_capacity), detector.count);
            try expectClickCount(detector.nextAction().?, 2);
            try expectClickCount(detector.nextAction().?, 3);
            try expectClickCount(detector.nextAction().?, 4);
            try expectClickCount(detector.nextAction().?, 5);
            try testing.expect(detector.nextAction() == null);
        }

        fn testQueueOverflowAfterWrapPreservesFifoOrder() !void {
            const testing = lib.testing;

            var detector = ClickDetector.initDefault();

            detector.queueAction(.{ .gesture = .{ .click = 1 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 2 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 3 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 4 }, .ctx = null });

            try expectClickCount(detector.nextAction().?, 1);

            detector.queueAction(.{ .gesture = .{ .click = 5 }, .ctx = null });
            detector.queueAction(.{ .gesture = .{ .click = 6 }, .ctx = null });

            try testing.expectEqual(@as(usize, action_queue_capacity), detector.count);
            try expectClickCount(detector.nextAction().?, 3);
            try expectClickCount(detector.nextAction().?, 4);
            try expectClickCount(detector.nextAction().?, 5);
            try expectClickCount(detector.nextAction().?, 6);
            try testing.expect(detector.nextAction() == null);
        }

        fn expectClickCount(action: Action, expected_count: u16) !void {
            const testing = lib.testing;

            switch (action.gesture) {
                .click => |count| try testing.expectEqual(expected_count, count),
                else => try testing.expect(false),
            }
        }

        fn expectLongPressDuration(action: Action, expected_held_ns: u64) !void {
            const testing = lib.testing;

            switch (action.gesture) {
                .long_press_ns => |held_ns| try testing.expectEqual(expected_held_ns, held_ns),
                else => try testing.expect(false),
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
