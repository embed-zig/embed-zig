const stdz = @import("stdz");
const motion = @import("motion");
const Context = @import("../../event/Context.zig");
const button_event = @import("event.zig");
const button_state = @import("state.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const Node = @import("../../pipeline/Node.zig");
const testing_api = @import("testing");

const Reducer = @This();
const State = button_state.Detected;
const GroupedState = button_state.Grouped;
const SingleState = button_state.Single;
const ClickDetector = motion.ClickDetector;

const Key = struct {
    source_id: u32,
    button_id: ?u32 = null,
};

pub const default_long_press_ns: u64 = ClickDetector.default_long_press_ns;
pub const default_multi_click_window_ns: u64 = ClickDetector.default_multi_click_window_ns;

allocator: stdz.mem.Allocator,
states: stdz.AutoHashMap(Key, ClickDetector),
out: ?Emitter = null,
long_press_ns: u64 = default_long_press_ns,
multi_click_window_ns: u64 = default_multi_click_window_ns,

pub fn init(allocator: stdz.mem.Allocator) Reducer {
    return .{
        .allocator = allocator,
        .states = stdz.AutoHashMap(Key, ClickDetector).init(allocator),
        .out = null,
        .long_press_ns = default_long_press_ns,
        .multi_click_window_ns = default_multi_click_window_ns,
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

pub fn process(self: *Reducer, message: Message) !usize {
    return switch (message.body) {
        .tick => blk: {
            const emitted = try self.flushAllDue(message.timestamp_ns);
            break :blk emitted + try self.forward(message);
        },
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

pub fn reduce(store: anytype, message: Message, emit: Emitter) !usize {
    _ = emit;

    switch (message.body) {
        .button_gesture => |button| {
            const next_state: State = switch (button.gesture) {
                .click => |count| .{
                    .source_id = button.source_id,
                    .button_id = button.button_id,
                    .gesture_kind = .click,
                    .click_count = count,
                    .long_press_ns = 0,
                },
                .long_press_ns => |held_ns| .{
                    .source_id = button.source_id,
                    .button_id = button.button_id,
                    .gesture_kind = .long_press,
                    .click_count = 0,
                    .long_press_ns = held_ns,
                },
            };
            store.set(next_state);
            return 0;
        },
        else => return 0,
    }
}

pub fn reduceGrouped(store: anytype, message: Message, emit: Emitter) !usize {
    _ = emit;

    switch (message.body) {
        .raw_grouped_button => |button| {
            store.set(GroupedState{
                .source_id = button.source_id,
                .button_id = button.button_id,
                .pressed = button.pressed,
            });
            return 0;
        },
        else => return 0,
    }
}

pub fn reduceSingle(store: anytype, message: Message, emit: Emitter) !usize {
    _ = emit;

    switch (message.body) {
        .raw_single_button => |button| {
            store.set(SingleState{
                .source_id = button.source_id,
                .pressed = button.pressed,
            });
            return 0;
        },
        else => return 0,
    }
}

fn flushAllDue(self: *Reducer, timestamp_ns: i128) !usize {
    var emitted: usize = 0;
    var iter = self.states.iterator();
    while (iter.next()) |entry| {
        emitted += try self.flushDue(timestamp_ns, entry.key_ptr.*, entry.value_ptr);
    }
    return emitted;
}

fn processRaw(
    self: *Reducer,
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
        gop.value_ptr.* = ClickDetector.init(.{
            .long_press_ns = self.long_press_ns,
            .multi_click_window_ns = self.multi_click_window_ns,
        });
    }

    const detector = gop.value_ptr;
    var emitted = try self.flushDue(timestamp_ns, key, detector);

    if (detector.update(.{
        .timestamp_ns = timestamp_ns,
        .pressed = pressed,
        .ctx = ctx,
    })) |action| {
        emitted += try self.emitGesture(
            source_id,
            button_id,
            gestureValue(action.gesture),
            action.ctx,
        );
    }
    while (detector.nextAction()) |action| {
        emitted += try self.emitGesture(
            source_id,
            button_id,
            gestureValue(action.gesture),
            action.ctx,
        );
    }
    return emitted;
}

fn flushDue(
    self: *Reducer,
    timestamp_ns: i128,
    key: Key,
    detector: *ClickDetector,
) !usize {
    var emitted: usize = 0;
    self.syncDetectorConfig(detector);

    if (detector.flush(timestamp_ns)) |action| {
        emitted += try self.emitGesture(
            key.source_id,
            key.button_id,
            gestureValue(action.gesture),
            action.ctx,
        );
    }
    while (detector.nextAction()) |action| {
        emitted += try self.emitGesture(
            key.source_id,
            key.button_id,
            gestureValue(action.gesture),
            action.ctx,
        );
    }

    return emitted;
}

fn syncDetectorConfig(self: *const Reducer, detector: *ClickDetector) void {
    detector.long_press_ns = self.long_press_ns;
    detector.multi_click_window_ns = self.multi_click_window_ns;
}

fn gestureValue(gesture: ClickDetector.Gesture) button_event.Detected.Value {
    return switch (gesture) {
        .click => |count| .{ .click = count },
        .long_press_ns => |held_ns| .{ .long_press_ns = held_ns },
    };
}

fn emitGesture(
    self: *Reducer,
    source_id: u32,
    button_id: ?u32,
    gesture: button_event.Detected.Value,
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

fn forward(self: *Reducer, message: Message) !usize {
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
                        .tick => {},
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl = Reducer.init(testing.allocator);
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
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
                @as(usize, 2),
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
                        .tick => {},
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl = Reducer.init(testing.allocator);
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
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
                @as(usize, 2),
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

        fn longPressEmitsUpdatedDuration(testing: anytype) !void {
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
                        .tick => {},
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl = Reducer.init(testing.allocator);
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
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
                @as(usize, 2),
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

            try testing.expectEqual(
                @as(usize, 2),
                try detector.process(.{
                    .origin = .timer,
                    .timestamp_ns = 10 + @as(i128, default_long_press_ns) + 75,
                    .body = .{
                        .tick = .{},
                    },
                }),
            );
            try testing.expectEqual(default_long_press_ns + 75, collector.last_long_press_ns);
            try testing.expectEqual(@as(usize, 2), collector.count);

            try testing.expectEqual(@as(usize, 1), try detector.process(.{
                .origin = .source,
                .timestamp_ns = 10 + @as(i128, default_long_press_ns) + 100,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 9,
                        .pressed = false,
                    },
                },
            }));
            try testing.expectEqual(default_long_press_ns + 100, collector.last_long_press_ns);
            try testing.expectEqual(@as(usize, 3), collector.count);
        }

        fn updatedLongPressThresholdAppliesToExistingKey(testing: anytype) !void {
            const Collector = struct {
                long_press_ns: u64 = 0,
                count: usize = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .button_gesture => |button| {
                            switch (button.gesture) {
                                .click => return error.UnexpectedGesture,
                                .long_press_ns => |held_ns| self.long_press_ns = held_ns,
                            }
                            self.count += 1;
                        },
                        .tick => {},
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl = Reducer.init(testing.allocator);
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
            detector.bindOutput(Emitter.init(&collector));

            _ = try detector.process(.{
                .origin = .source,
                .timestamp_ns = 10,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 11,
                        .pressed = true,
                    },
                },
            });

            detector_impl.long_press_ns = 100;
            try testing.expectEqual(
                @as(usize, 2),
                try detector.process(.{
                    .origin = .timer,
                    .timestamp_ns = 110,
                    .body = .{
                        .tick = .{},
                    },
                }),
            );
            try testing.expectEqual(@as(u64, 100), collector.long_press_ns);
            try testing.expectEqual(@as(usize, 1), collector.count);
        }

        fn updatedMultiClickWindowAppliesToExistingKey(testing: anytype) !void {
            const Collector = struct {
                click_count: u16 = 0,
                count: usize = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .button_gesture => |button| {
                            switch (button.gesture) {
                                .click => |count| self.click_count = count,
                                .long_press_ns => return error.UnexpectedGesture,
                            }
                            self.count += 1;
                        },
                        .tick => {},
                        else => return error.UnexpectedMessage,
                    }
                }
            };

            var detector_impl = Reducer.init(testing.allocator);
            defer detector_impl.deinit();
            var collector = Collector{};
            var detector = detector_impl.node();
            detector.bindOutput(Emitter.init(&collector));

            _ = try detector.process(.{
                .origin = .source,
                .timestamp_ns = 1_000,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 13,
                        .pressed = true,
                    },
                },
            });
            _ = try detector.process(.{
                .origin = .source,
                .timestamp_ns = 1_010,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 13,
                        .pressed = false,
                    },
                },
            });

            detector_impl.multi_click_window_ns = 50;
            try testing.expectEqual(
                @as(usize, 2),
                try detector.process(.{
                    .origin = .timer,
                    .timestamp_ns = 1_060,
                    .body = .{
                        .tick = .{},
                    },
                }),
            );
            try testing.expectEqual(@as(u16, 1), collector.click_count);
            try testing.expectEqual(@as(usize, 1), collector.count);
        }

        fn reduceGroupedUpdatesStore(testing: anytype) !void {
            const embed_std = @import("embed_std");
            const StoreObject = @import("../../store/Object.zig");

            const GroupedStore = StoreObject.make(embed_std.std, GroupedState, .grouped_button);
            var store = GroupedStore.init(testing.allocator, .{});
            defer store.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};

            try testing.expectEqual(@as(usize, 0), try reduceGrouped(&store, .{
                .origin = .source,
                .body = .{
                    .raw_grouped_button = .{
                        .source_id = 3,
                        .button_id = 1,
                        .pressed = true,
                    },
                },
            }, Emitter.init(&sink)));

            store.tick();
            const next = store.get();
            try testing.expectEqual(@as(u32, 3), next.source_id);
            try testing.expectEqual(@as(?u32, 1), next.button_id);
            try testing.expect(next.pressed);
        }

        fn reduceSingleUpdatesStore(testing: anytype) !void {
            const embed_std = @import("embed_std");
            const StoreObject = @import("../../store/Object.zig");

            const SingleStore = StoreObject.make(embed_std.std, SingleState, .single_button);
            var store = SingleStore.init(testing.allocator, .{});
            defer store.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};

            try testing.expectEqual(@as(usize, 0), try reduceSingle(&store, .{
                .origin = .source,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 9,
                        .pressed = true,
                    },
                },
            }, Emitter.init(&sink)));

            store.tick();
            const next = store.get();
            try testing.expectEqual(@as(u32, 9), next.source_id);
            try testing.expect(next.pressed);
        }

        fn reduceUpdatesStore(testing: anytype) !void {
            const embed_std = @import("embed_std");
            const StoreObject = @import("../../store/Object.zig");

            const GestureStore = StoreObject.make(embed_std.std, State, .button_gesture);
            var store = GestureStore.init(testing.allocator, .{});
            defer store.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};

            try testing.expectEqual(@as(usize, 0), try reduce(&store, .{
                .origin = .node,
                .body = .{
                    .button_gesture = .{
                        .source_id = 5,
                        .button_id = 2,
                        .gesture = .{ .click = 3 },
                    },
                },
            }, Emitter.init(&sink)));

            store.tick();
            const next = store.get();
            try testing.expectEqual(@as(u32, 5), next.source_id);
            try testing.expectEqual(@as(?u32, 2), next.button_id);
            try testing.expect(next.gesture_kind != null);
            try testing.expectEqual(@as(@TypeOf(next.gesture_kind.?), .click), next.gesture_kind.?);
            try testing.expectEqual(@as(u16, 3), next.click_count);
            try testing.expectEqual(@as(u64, 0), next.long_press_ns);
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
            TestCase.longPressEmitsUpdatedDuration(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.updatedLongPressThresholdAppliesToExistingKey(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.updatedMultiClickWindowAppliesToExistingKey(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.reduceSingleUpdatesStore(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.reduceGroupedUpdatesStore(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.reduceUpdatesStore(testing) catch |err| {
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
