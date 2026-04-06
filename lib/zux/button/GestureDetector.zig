const embed = @import("embed");
const Context = @import("../event/Context.zig");
const Emitter = @import("../pipeline/Emitter.zig");
const Message = @import("../pipeline/Message.zig");
const Node = @import("../pipeline/Node.zig");
const testing_api = @import("testing");

const GestureDetector = @This();

pub const Event = struct {
    pub const kind = .button_gesture;

    pub const Gesture = union(enum) {
        click: u16,
        long_press_ns: u64,
    };

    source_id: u32,
    button_id: ?u32 = null,
    gesture: Gesture,
    ctx: Context.Type = null,
};

const Key = struct {
    source_id: u32,
    button_id: ?u32 = null,
};

const PendingPress = struct {
    pressed_at_ns: i128,
    ctx: Context.Type,
};

const PendingClicks = struct {
    last_click_at_ns: i128,
    count: u16,
    ctx: Context.Type,
};

const PressState = struct {
    pending_press: ?PendingPress = null,
    pending_clicks: ?PendingClicks = null,
};

pub const default_long_press_ns: u64 = 500 * embed.time.ns_per_ms;
pub const default_multi_click_window_ns: u64 = 300 * embed.time.ns_per_ms;

allocator: embed.mem.Allocator,
states: embed.AutoHashMap(Key, PressState),
out: ?Emitter = null,
long_press_ns: u64 = default_long_press_ns,
multi_click_window_ns: u64 = default_multi_click_window_ns,

pub fn init(self: *GestureDetector, allocator: embed.mem.Allocator) Node {
    self.* = .{
        .allocator = allocator,
        .states = embed.AutoHashMap(Key, PressState).init(allocator),
        .out = null,
        .long_press_ns = default_long_press_ns,
        .multi_click_window_ns = default_multi_click_window_ns,
    };
    return Node.init(GestureDetector, self);
}

pub fn deinit(self: *GestureDetector) void {
    self.states.deinit();
}

pub fn bindOutput(self: *GestureDetector, out: Emitter) void {
    self.out = out;
}

pub fn process(self: *GestureDetector, message: Message) !usize {
    return switch (message.body) {
        .tick => self.flushAllDue(message.timestamp_ns),
        .raw_single_button => |button| self.processRaw(
            message.timestamp_ns,
            button.source_id,
            null,
            button.pressed,
            button.ctx,
        ),
        .raw_grouped_button => |button| self.processRaw(
            message.timestamp_ns,
            button.source_id,
            button.button_id,
            button.pressed,
            button.ctx,
        ),
        else => self.forward(message),
    };
}

fn flushAllDue(self: *GestureDetector, timestamp_ns: i128) !usize {
    var emitted: usize = 0;
    var iter = self.states.iterator();
    while (iter.next()) |entry| {
        emitted += try self.flushDue(timestamp_ns, entry.key_ptr.*, entry.value_ptr);
    }
    return emitted;
}

fn processRaw(
    self: *GestureDetector,
    timestamp_ns: i128,
    source_id: u32,
    button_id: ?u32,
    pressed: bool,
    ctx: Context.Type,
) !usize {
    const key: Key = .{
        .source_id = source_id,
        .button_id = button_id,
    };
    const gop = try self.states.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }

    const state = gop.value_ptr;
    var emitted = try self.flushDue(timestamp_ns, key, state);

    if (pressed) {
        if (state.pending_press != null) return emitted;

        state.pending_press = .{
            .pressed_at_ns = timestamp_ns,
            .ctx = ctx,
        };
        return emitted;
    }

    const pending_press = state.pending_press orelse return emitted;
    state.pending_press = null;

    const held_ns = elapsedNs(pending_press.pressed_at_ns, timestamp_ns);
    if (held_ns >= self.long_press_ns) {
        state.pending_clicks = null;
        emitted += try self.emitGesture(
            source_id,
            button_id,
            .{ .long_press_ns = held_ns },
            ctx,
        );
        return emitted;
    }

    if (state.pending_clicks) |*pending_clicks| {
        if (elapsedNs(pending_clicks.last_click_at_ns, timestamp_ns) < self.multi_click_window_ns) {
            pending_clicks.count += 1;
            pending_clicks.last_click_at_ns = timestamp_ns;
            pending_clicks.ctx = ctx;
            return emitted;
        }
    }

    state.pending_clicks = .{
        .last_click_at_ns = timestamp_ns,
        .count = 1,
        .ctx = ctx,
    };
    return emitted;
}

fn flushDue(
    self: *GestureDetector,
    timestamp_ns: i128,
    key: Key,
    state: *PressState,
) !usize {
    var emitted: usize = 0;

    if (state.pending_press) |pending_press| {
        const held_ns = elapsedNs(pending_press.pressed_at_ns, timestamp_ns);
        if (held_ns >= self.long_press_ns) {
            state.pending_press = null;
            state.pending_clicks = null;
            emitted += try self.emitGesture(
                key.source_id,
                key.button_id,
                .{ .long_press_ns = held_ns },
                pending_press.ctx,
            );
        }
    }

    if (state.pending_clicks) |pending_clicks| {
        const quiet_ns = elapsedNs(pending_clicks.last_click_at_ns, timestamp_ns);
        if (quiet_ns >= self.multi_click_window_ns) {
            state.pending_clicks = null;
            emitted += try self.emitGesture(
                key.source_id,
                key.button_id,
                .{ .click = pending_clicks.count },
                pending_clicks.ctx,
            );
        }
    }

    return emitted;
}

fn elapsedNs(start_ns: i128, end_ns: i128) u64 {
    if (end_ns <= start_ns) return 0;

    const delta_ns = end_ns - start_ns;
    const max_u64_ns: i128 = @intCast(embed.math.maxInt(u64));
    if (delta_ns >= max_u64_ns) return embed.math.maxInt(u64);
    return @intCast(delta_ns);
}

fn emitGesture(
    self: *GestureDetector,
    source_id: u32,
    button_id: ?u32,
    gesture: Event.Gesture,
    ctx: Context.Type,
) !usize {
    if (self.out) |out| {
        try out.emit(.{
            .origin = .node,
            .body = .{
                .button_gesture = .{
                    .source_id = source_id,
                    .button_id = button_id,
                    .gesture = gesture,
                    .ctx = ctx,
                },
            },
        });
        return 1;
    }

    return 0;
}

fn forward(self: *GestureDetector, message: Message) !usize {
    if (self.out) |out| {
        try out.emit(message);
        return 1;
    }
    return 0;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn rawSingleButtonClickEmitsCountAfterTick(testing: anytype) !void {
            const Collector = struct {
                count: usize = 0,
                last_click_count: u16 = 0,
                last_long_press_ns: u64 = 0,
                last_button_id: ?u32 = 123,

                pub fn emit(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .button_gesture => |button| {
                            self.last_button_id = button.button_id;
                            switch (button.gesture) {
                                .click => |click_count| self.last_click_count = click_count,
                                .long_press_ns => |hold_ns| self.last_long_press_ns = hold_ns,
                            }
                            self.count += 1;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl: GestureDetector = undefined;
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.init(testing.allocator);
            detector.bindOutput(Emitter.init(&collector));

            try testing.expectEqual(@as(usize, 0), try detector.process(.{
                .origin = .source,
                .timestamp_ns = 10,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 1,
                        .pressed = true,
                    },
                },
            }));
            try testing.expectEqual(@as(usize, 0), try detector.process(.{
                .origin = .source,
                .timestamp_ns = 20,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 1,
                        .pressed = false,
                    },
                },
            }));
            try testing.expectEqual(
                @as(usize, 1),
                try detector.process(.{
                    .origin = .timer,
                    .timestamp_ns = 20 + @as(i128, default_multi_click_window_ns),
                    .body = .{
                        .tick = .{},
                    },
                }),
            );

            try testing.expectEqual(@as(usize, 1), collector.count);
            try testing.expectEqual(@as(u16, 1), collector.last_click_count);
            try testing.expectEqual(@as(u64, 0), collector.last_long_press_ns);
            try testing.expectEqual(@as(?u32, null), collector.last_button_id);
        }

        fn rawGroupedButtonFourClicksEmitClickCount(testing: anytype) !void {
            const Collector = struct {
                last_click_count: u16 = 0,
                last_button_id: ?u32 = null,
                count: usize = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .button_gesture => |button| {
                            switch (button.gesture) {
                                .click => |click_count| self.last_click_count = click_count,
                                .long_press_ns => return error.UnexpectedGesture,
                            }
                            self.last_button_id = button.button_id;
                            self.count += 1;
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl: GestureDetector = undefined;
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.init(testing.allocator);
            detector.bindOutput(Emitter.init(&collector));

            inline for ([_]i128{ 10, 30, 50, 70 }) |start_ns| {
                _ = try detector.process(.{
                    .origin = .source,
                    .timestamp_ns = start_ns,
                    .body = .{
                        .raw_grouped_button = .{
                            .source_id = 7,
                            .button_id = 3,
                            .pressed = true,
                        },
                    },
                });
                _ = try detector.process(.{
                    .origin = .source,
                    .timestamp_ns = start_ns + 10,
                    .body = .{
                        .raw_grouped_button = .{
                            .source_id = 7,
                            .button_id = 3,
                            .pressed = false,
                        },
                    },
                });
            }
            try testing.expectEqual(
                @as(usize, 1),
                try detector.process(.{
                    .origin = .timer,
                    .timestamp_ns = 80 + @as(i128, default_multi_click_window_ns),
                    .body = .{
                        .tick = .{},
                    },
                }),
            );

            try testing.expectEqual(@as(u16, 4), collector.last_click_count);
            try testing.expectEqual(@as(?u32, 3), collector.last_button_id);
            try testing.expectEqual(@as(usize, 1), collector.count);
        }

        fn longPressEmitsDuration(testing: anytype) !void {
            const Collector = struct {
                count: usize = 0,
                last_long_press_ns: u64 = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .button_gesture => |button| switch (button.gesture) {
                            .click => return error.UnexpectedGesture,
                            .long_press_ns => |hold_ns| {
                                self.last_long_press_ns = hold_ns;
                                self.count += 1;
                            },
                        },
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl: GestureDetector = undefined;
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.init(testing.allocator);
            detector.bindOutput(Emitter.init(&collector));

            _ = try detector.process(.{
                .origin = .source,
                .timestamp_ns = 10,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 9,
                        .pressed = true,
                    },
                },
            });
            try testing.expectEqual(
                @as(usize, 1),
                try detector.process(.{
                    .origin = .timer,
                    .timestamp_ns = 10 + @as(i128, default_long_press_ns) + 25,
                    .body = .{
                        .tick = .{},
                    },
                }),
            );
            try testing.expectEqual(default_long_press_ns + 25, collector.last_long_press_ns);
            try testing.expectEqual(@as(usize, 1), collector.count);

            try testing.expectEqual(@as(usize, 0), try detector.process(.{
                .origin = .source,
                .timestamp_ns = 10 + @as(i128, default_long_press_ns) + 50,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 9,
                        .pressed = false,
                    },
                },
            }));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            TestCase.rawSingleButtonClickEmitsCountAfterTick(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rawGroupedButtonFourClicksEmitClickCount(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.longPressEmitsDuration(testing) catch |err| {
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
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
