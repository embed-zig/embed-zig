const glib = @import("glib");
const motion = @import("motion");
const button_event = @import("event.zig");
const button_state = @import("state.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const Node = @import("../../pipeline/Node.zig");

const Reducer = @This();
const State = button_state.Detected;
const GroupedState = button_state.Grouped;
const SingleState = button_state.Single;
const ClickDetector = motion.ClickDetector;

const Key = struct {
    source_id: u32,
    button_id: ?u32 = null,
};

pub const default_long_press: glib.time.duration.Duration = ClickDetector.default_long_press;
pub const default_multi_click_window: glib.time.duration.Duration = ClickDetector.default_multi_click_window;

allocator: glib.std.mem.Allocator,
states: glib.std.AutoHashMap(Key, ClickDetector),
out: ?Emitter = null,
long_press: glib.time.duration.Duration = default_long_press,
multi_click_window: glib.time.duration.Duration = default_multi_click_window,

pub fn init(allocator: glib.std.mem.Allocator) Reducer {
    return .{
        .allocator = allocator,
        .states = glib.std.AutoHashMap(Key, ClickDetector).init(allocator),
        .out = null,
        .long_press = default_long_press,
        .multi_click_window = default_multi_click_window,
    };
}

pub fn node(self: *Reducer) Node {
    return Node.init(Reducer, self);
}

pub fn deinit(self: *Reducer) void {
    self.states.deinit();
}

pub fn bindOutput(self: *Reducer, out: Emitter) void {
    self.out = out;
}

pub fn process(self: *Reducer, message: Message) !void {
    switch (message.body) {
        .tick => {
            try self.flushAllDue(message.timestamp);
            try self.forward(message);
        },
        .raw_single_button => |button| {
            try self.processRaw(
                message.timestamp,
                button.source_id,
                null,
                button.pressed,
            );
            try self.forward(message);
        },
        .raw_grouped_button => |button| {
            try self.processRaw(
                message.timestamp,
                button.source_id,
                button.button_id,
                button.pressed,
            );
            try self.forward(message);
        },
        else => try self.forward(message),
    }
}

pub fn reduce(store: anytype, message: Message, emit: Emitter) !void {
    _ = emit;

    switch (message.body) {
        .button_gesture => |button| {
            store.invoke(button, struct {
                fn apply(state: *State, event: @TypeOf(button)) void {
                    state.seq +%= 1;
                    state.source_id = event.source_id;
                    state.button_id = event.button_id;
                    state.pressed_at = event.pressed_at;
                    switch (event.gesture) {
                        .click => |count| {
                            state.gesture_kind = .click;
                            state.click_count = count;
                            state.long_press = 0;
                        },
                        .long_press => |held| {
                            state.gesture_kind = .long_press;
                            state.click_count = 0;
                            state.long_press = held;
                        },
                    }
                }
            }.apply);
        },
        else => return,
    }
}

pub fn reduceGrouped(store: anytype, message: Message, emit: Emitter) !void {
    _ = emit;

    switch (message.body) {
        .raw_grouped_button => |button| {
            store.set(GroupedState{
                .source_id = button.source_id,
                .button_id = button.button_id,
                .pressed = button.pressed,
            });
        },
        else => return,
    }
}

pub fn reduceSingle(store: anytype, message: Message, emit: Emitter) !void {
    _ = emit;

    switch (message.body) {
        .raw_single_button => |button| {
            store.set(SingleState{
                .source_id = button.source_id,
                .pressed = button.pressed,
            });
        },
        else => return,
    }
}

fn flushAllDue(self: *Reducer, timestamp: glib.time.instant.Time) !void {
    var iter = self.states.iterator();
    while (iter.next()) |entry| {
        try self.flushDue(timestamp, entry.key_ptr.*, entry.value_ptr);
    }
}

fn processRaw(
    self: *Reducer,
    timestamp: glib.time.instant.Time,
    source_id: u32,
    button_id: ?u32,
    pressed: bool,
) !void {
    const key: Key = .{
        .source_id = source_id,
        .button_id = button_id,
    };
    const gop = try self.states.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = ClickDetector.init(.{
            .long_press = self.long_press,
            .multi_click_window = self.multi_click_window,
        });
    }

    const detector = gop.value_ptr;
    try self.flushDue(timestamp, key, detector);

    if (detector.update(.{
        .timestamp = timestamp,
        .pressed = pressed,
    })) |action| {
        try self.emitGesture(
            timestamp,
            source_id,
            button_id,
            action.pressed_at,
            gestureValue(action.gesture),
        );
    }
    while (detector.nextAction()) |action| {
        try self.emitGesture(
            timestamp,
            source_id,
            button_id,
            action.pressed_at,
            gestureValue(action.gesture),
        );
    }
}

fn flushDue(
    self: *Reducer,
    timestamp: glib.time.instant.Time,
    key: Key,
    detector: *ClickDetector,
) !void {
    self.syncDetectorConfig(detector);

    if (detector.flush(timestamp)) |action| {
        try self.emitGesture(
            timestamp,
            key.source_id,
            key.button_id,
            action.pressed_at,
            gestureValue(action.gesture),
        );
    }
    while (detector.nextAction()) |action| {
        try self.emitGesture(
            timestamp,
            key.source_id,
            key.button_id,
            action.pressed_at,
            gestureValue(action.gesture),
        );
    }
}

fn syncDetectorConfig(self: *const Reducer, detector: *ClickDetector) void {
    detector.long_press = self.long_press;
    detector.multi_click_window = self.multi_click_window;
}

fn gestureValue(gesture: ClickDetector.Gesture) button_event.Detected.Value {
    return switch (gesture) {
        .click => |count| .{ .click = count },
        .long_press => |held| .{ .long_press = held },
    };
}

fn emitGesture(
    self: *Reducer,
    timestamp: glib.time.instant.Time,
    source_id: u32,
    button_id: ?u32,
    pressed_at: glib.time.instant.Time,
    gesture: button_event.Detected.Value,
) !void {
    if (self.out) |out| {
        try out.emit(.{
            .origin = .node,
            .timestamp = timestamp,
            .body = .{
                .button_gesture = .{
                    .source_id = source_id,
                    .button_id = button_id,
                    .pressed_at = pressed_at,
                    .gesture = gesture,
                },
            },
        });
    }
}

fn forward(self: *Reducer, message: Message) !void {
    if (self.out) |out| {
        try out.emit(message);
    }
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn rawSingleButtonClickEmitsCountAfterTick() !void {
            const Collector = struct {
                count: usize = 0,
                last_click_count: u16 = 0,
                last_long_press: glib.time.duration.Duration = 0,
                last_button_id: ?u32 = 123,
                last_pressed_at: glib.time.instant.Time = 0,
                last_timestamp: glib.time.instant.Time = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .button_gesture => |button| {
                            self.last_button_id = button.button_id;
                            self.last_pressed_at = button.pressed_at;
                            self.last_timestamp = message.timestamp;
                            switch (button.gesture) {
                                .click => |click_count| self.last_click_count = click_count,
                                .long_press => |held| self.last_long_press = held,
                            }
                            self.count += 1;
                        },
                        .raw_single_button => {},
                        .tick => {},
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl = Reducer.init(grt.std.testing.allocator);
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
            detector.bindOutput(Emitter.init(&collector));

            try detector.process(.{
                .origin = .source,
                .timestamp = 10,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 1,
                        .pressed = true,
                    },
                },
            });
            try detector.process(.{
                .origin = .source,
                .timestamp = 20,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 1,
                        .pressed = false,
                    },
                },
            });
            try detector.process(.{
                .origin = .timer,
                .timestamp = glib.time.instant.add(20, default_multi_click_window),
                .body = .{
                    .tick = .{},
                },
            });

            try grt.std.testing.expectEqual(@as(usize, 1), collector.count);
            try grt.std.testing.expectEqual(@as(u16, 1), collector.last_click_count);
            try grt.std.testing.expectEqual(@as(glib.time.duration.Duration, 0), collector.last_long_press);
            try grt.std.testing.expectEqual(@as(?u32, null), collector.last_button_id);
            try grt.std.testing.expectEqual(@as(glib.time.instant.Time, 10), collector.last_pressed_at);
            try grt.std.testing.expectEqual(
                glib.time.instant.add(20, default_multi_click_window),
                collector.last_timestamp,
            );
        }

        fn rawGroupedButtonFourClicksEmitClickCount() !void {
            const Collector = struct {
                last_click_count: u16 = 0,
                last_button_id: ?u32 = null,
                last_pressed_at: glib.time.instant.Time = 0,
                count: usize = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .button_gesture => |button| {
                            switch (button.gesture) {
                                .click => |click_count| self.last_click_count = click_count,
                                .long_press => return error.UnexpectedGesture,
                            }
                            self.last_button_id = button.button_id;
                            self.last_pressed_at = button.pressed_at;
                            self.count += 1;
                        },
                        .raw_grouped_button => {},
                        .tick => {},
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl = Reducer.init(grt.std.testing.allocator);
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
            detector.bindOutput(Emitter.init(&collector));

            inline for ([_]glib.time.instant.Time{ 10, 30, 50, 70 }) |start| {
                try detector.process(.{
                    .origin = .source,
                    .timestamp = start,
                    .body = .{
                        .raw_grouped_button = .{
                            .source_id = 7,
                            .button_id = 3,
                            .pressed = true,
                        },
                    },
                });
                try detector.process(.{
                    .origin = .source,
                    .timestamp = glib.time.instant.add(start, 10),
                    .body = .{
                        .raw_grouped_button = .{
                            .source_id = 7,
                            .button_id = 3,
                            .pressed = false,
                        },
                    },
                });
            }
            try detector.process(.{
                .origin = .timer,
                .timestamp = glib.time.instant.add(80, default_multi_click_window),
                .body = .{
                    .tick = .{},
                },
            });

            try grt.std.testing.expectEqual(@as(u16, 4), collector.last_click_count);
            try grt.std.testing.expectEqual(@as(?u32, 3), collector.last_button_id);
            try grt.std.testing.expectEqual(@as(glib.time.instant.Time, 10), collector.last_pressed_at);
            try grt.std.testing.expectEqual(@as(usize, 1), collector.count);
        }

        fn longPressEmitsUpdatedDuration() !void {
            const Collector = struct {
                count: usize = 0,
                last_long_press: glib.time.duration.Duration = 0,
                last_pressed_at: glib.time.instant.Time = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .button_gesture => |button| switch (button.gesture) {
                            .click => return error.UnexpectedGesture,
                            .long_press => |held| {
                                self.last_long_press = held;
                                self.last_pressed_at = button.pressed_at;
                                self.count += 1;
                            },
                        },
                        .raw_single_button => {},
                        .tick => {},
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl = Reducer.init(grt.std.testing.allocator);
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
            detector.bindOutput(Emitter.init(&collector));

            try detector.process(.{
                .origin = .source,
                .timestamp = 10,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 9,
                        .pressed = true,
                    },
                },
            });
            try detector.process(.{
                .origin = .timer,
                .timestamp = glib.time.instant.add(10, default_long_press + 25),
                .body = .{
                    .tick = .{},
                },
            });
            try grt.std.testing.expectEqual(default_long_press + 25, collector.last_long_press);
            try grt.std.testing.expectEqual(@as(glib.time.instant.Time, 10), collector.last_pressed_at);
            try grt.std.testing.expectEqual(@as(usize, 1), collector.count);

            try detector.process(.{
                .origin = .timer,
                .timestamp = glib.time.instant.add(10, default_long_press + 75),
                .body = .{
                    .tick = .{},
                },
            });
            try grt.std.testing.expectEqual(default_long_press + 75, collector.last_long_press);
            try grt.std.testing.expectEqual(@as(glib.time.instant.Time, 10), collector.last_pressed_at);
            try grt.std.testing.expectEqual(@as(usize, 2), collector.count);

            try detector.process(.{
                .origin = .source,
                .timestamp = glib.time.instant.add(10, default_long_press + 100),
                .body = .{
                    .raw_single_button = .{
                        .source_id = 9,
                        .pressed = false,
                    },
                },
            });
            try grt.std.testing.expectEqual(default_long_press + 100, collector.last_long_press);
            try grt.std.testing.expectEqual(@as(glib.time.instant.Time, 10), collector.last_pressed_at);
            try grt.std.testing.expectEqual(@as(usize, 3), collector.count);
        }

        fn updatedLongPressThresholdAppliesToExistingKey() !void {
            const Collector = struct {
                long_press: glib.time.duration.Duration = 0,
                pressed_at: glib.time.instant.Time = 0,
                count: usize = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .button_gesture => |button| {
                            switch (button.gesture) {
                                .click => return error.UnexpectedGesture,
                                .long_press => |held| self.long_press = held,
                            }
                            self.pressed_at = button.pressed_at;
                            self.count += 1;
                        },
                        .raw_single_button => {},
                        .tick => {},
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl = Reducer.init(grt.std.testing.allocator);
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
            detector.bindOutput(Emitter.init(&collector));

            try detector.process(.{
                .origin = .source,
                .timestamp = 10,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 11,
                        .pressed = true,
                    },
                },
            });

            detector_impl.long_press = 100;
            try detector.process(.{
                .origin = .timer,
                .timestamp = 110,
                .body = .{
                    .tick = .{},
                },
            });
            try grt.std.testing.expectEqual(@as(glib.time.duration.Duration, 100), collector.long_press);
            try grt.std.testing.expectEqual(@as(glib.time.instant.Time, 10), collector.pressed_at);
            try grt.std.testing.expectEqual(@as(usize, 1), collector.count);
        }

        fn updatedMultiClickWindowAppliesToExistingKey() !void {
            const Collector = struct {
                click_count: u16 = 0,
                pressed_at: glib.time.instant.Time = 0,
                count: usize = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .button_gesture => |button| {
                            switch (button.gesture) {
                                .click => |count| self.click_count = count,
                                .long_press => return error.UnexpectedGesture,
                            }
                            self.pressed_at = button.pressed_at;
                            self.count += 1;
                        },
                        .raw_single_button => {},
                        .tick => {},
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl = Reducer.init(grt.std.testing.allocator);
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
            detector.bindOutput(Emitter.init(&collector));

            try detector.process(.{
                .origin = .source,
                .timestamp = 1_000,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 13,
                        .pressed = true,
                    },
                },
            });
            try detector.process(.{
                .origin = .source,
                .timestamp = 1_010,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 13,
                        .pressed = false,
                    },
                },
            });

            detector_impl.multi_click_window = 50;
            try detector.process(.{
                .origin = .timer,
                .timestamp = 1_060,
                .body = .{
                    .tick = .{},
                },
            });
            try grt.std.testing.expectEqual(@as(u16, 1), collector.click_count);
            try grt.std.testing.expectEqual(@as(glib.time.instant.Time, 1_000), collector.pressed_at);
            try grt.std.testing.expectEqual(@as(usize, 1), collector.count);
        }

        fn reduceGroupedUpdatesStore() !void {
            const StoreObject = @import("../../store/Object.zig");

            const GroupedStore = StoreObject.make(grt, GroupedState, .grouped_button);
            var store = GroupedStore.init(grt.std.testing.allocator, .{});
            defer store.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};

            try reduceGrouped(&store, .{
                .origin = .source,
                .body = .{
                    .raw_grouped_button = .{
                        .source_id = 3,
                        .button_id = 1,
                        .pressed = true,
                    },
                },
            }, Emitter.init(&sink));

            store.tick();
            const next = store.get();
            try grt.std.testing.expectEqual(@as(u32, 3), next.source_id);
            try grt.std.testing.expectEqual(@as(?u32, 1), next.button_id);
            try grt.std.testing.expect(next.pressed);
        }

        fn reduceSingleUpdatesStore() !void {
            const StoreObject = @import("../../store/Object.zig");

            const SingleStore = StoreObject.make(grt, SingleState, .single_button);
            var store = SingleStore.init(grt.std.testing.allocator, .{});
            defer store.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};

            try reduceSingle(&store, .{
                .origin = .source,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 9,
                        .pressed = true,
                    },
                },
            }, Emitter.init(&sink));

            store.tick();
            const next = store.get();
            try grt.std.testing.expectEqual(@as(u32, 9), next.source_id);
            try grt.std.testing.expect(next.pressed);
        }

        fn reduceUpdatesStore() !void {
            const StoreObject = @import("../../store/Object.zig");

            const GestureStore = StoreObject.make(grt, State, .button_gesture);
            var store = GestureStore.init(grt.std.testing.allocator, .{});
            defer store.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};

            try reduce(&store, .{
                .origin = .node,
                .body = .{
                    .button_gesture = .{
                        .source_id = 5,
                        .button_id = 2,
                        .pressed_at = 1234,
                        .gesture = .{ .click = 3 },
                    },
                },
            }, Emitter.init(&sink));

            store.tick();
            const next = store.get();
            try grt.std.testing.expectEqual(@as(u32, 5), next.source_id);
            try grt.std.testing.expectEqual(@as(?u32, 2), next.button_id);
            try grt.std.testing.expectEqual(@as(glib.time.instant.Time, 1234), next.pressed_at);
            try grt.std.testing.expect(next.gesture_kind != null);
            try grt.std.testing.expectEqual(@as(@TypeOf(next.gesture_kind.?), .click), next.gesture_kind.?);
            try grt.std.testing.expectEqual(@as(u16, 3), next.click_count);
            try grt.std.testing.expectEqual(@as(glib.time.duration.Duration, 0), next.long_press);
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

            TestCase.rawSingleButtonClickEmitsCountAfterTick() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rawGroupedButtonFourClicksEmitClickCount() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.longPressEmitsUpdatedDuration() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.updatedLongPressThresholdAppliesToExistingKey() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.updatedMultiClickWindowAppliesToExistingKey() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.reduceSingleUpdatesStore() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.reduceGroupedUpdatesStore() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.reduceUpdatesStore() catch |err| {
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
