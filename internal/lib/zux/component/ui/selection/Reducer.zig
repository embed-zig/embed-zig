const testing_api = @import("testing");

const Emitter = @import("../../../pipeline/Emitter.zig");
const Message = @import("../../../pipeline/Message.zig");
const Subscriber = @import("../../../store/Subscriber.zig");
const State = @import("State.zig");

pub fn make(comptime lib: type) type {
    const AtomicU64 = lib.atomic.Value(u64);
    const Mutex = lib.Thread.Mutex;
    const RwLock = lib.Thread.RwLock;
    const SubscriberList = lib.ArrayList(*Subscriber);

    return struct {
        const Self = @This();

        pub const StateType = State;

        allocator: lib.mem.Allocator,

        running_mu: Mutex = .{},
        running_state: State = .{},

        released_mu: RwLock = .{},
        released_state: State = .{},

        subscribers_mu: Mutex = .{},
        subscribers: SubscriberList = .empty,
        subscribers_notifying: bool = false,
        tick_count: AtomicU64 = AtomicU64.init(0),

        pub fn init(allocator: lib.mem.Allocator, initial: State) Self {
            const normalized = normalizeState(initial);
            return .{
                .allocator = allocator,
                .running_state = normalized,
                .released_state = normalized,
            };
        }

        pub fn deinit(self: *Self) void {
            self.subscribers_mu.lock();
            if (self.subscribers_notifying) {
                self.subscribers_mu.unlock();
                @panic("zux.component.ui.selection.deinit cannot run during subscriber notification");
            }
            self.subscribers.deinit(self.allocator);
            self.subscribers = .empty;
            self.subscribers_mu.unlock();
        }

        pub fn get(self: *Self) State {
            self.released_mu.lockShared();
            defer self.released_mu.unlockShared();
            return self.released_state;
        }

        pub fn subscribe(self: *Self, subscriber: *Subscriber) error{OutOfMemory}!void {
            self.subscribers_mu.lock();
            defer self.subscribers_mu.unlock();
            if (self.subscribers_notifying) {
                @panic("zux.component.ui.selection.subscribe cannot mutate subscribers during notification");
            }

            for (self.subscribers.items) |existing| {
                if (existing == subscriber) return;
            }
            try self.subscribers.append(self.allocator, subscriber);
        }

        pub fn unsubscribe(self: *Self, subscriber: *Subscriber) bool {
            self.subscribers_mu.lock();
            defer self.subscribers_mu.unlock();
            if (self.subscribers_notifying) {
                @panic("zux.component.ui.selection.unsubscribe cannot mutate subscribers during notification");
            }

            for (self.subscribers.items, 0..) |existing, i| {
                if (existing != subscriber) continue;
                _ = self.subscribers.orderedRemove(i);
                return true;
            }
            return false;
        }

        pub fn tick(self: *Self) void {
            const tick_count = self.tick_count.fetchAdd(1, .acq_rel) + 1;
            self.running_mu.lock();
            self.released_mu.lock();

            if (stateEql(self.running_state, self.released_state)) {
                self.released_mu.unlock();
                self.running_mu.unlock();
                return;
            }

            self.released_state = self.running_state;
            self.released_mu.unlock();
            self.running_mu.unlock();

            self.subscribers_mu.lock();
            if (self.subscribers_notifying) {
                self.subscribers_mu.unlock();
                @panic("zux.component.ui.selection.tick cannot reenter subscriber notification");
            }
            self.subscribers_notifying = true;
            const subscribers = self.subscribers.items;
            self.subscribers_mu.unlock();
            defer {
                self.subscribers_mu.lock();
                self.subscribers_notifying = false;
                self.subscribers_mu.unlock();
            }

            for (subscribers) |subscriber| {
                subscriber.notify(.{
                    .label = "ui_selection",
                    .tick_count = tick_count,
                });
            }
        }

        pub fn next(self: *Self) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();
            return nextLocked(&self.running_state);
        }

        pub fn prev(self: *Self) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();
            return prevLocked(&self.running_state);
        }

        pub fn set(self: *Self, index: usize) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();

            const next_index = normalizeIndex(index, self.running_state.count);
            if (self.running_state.index == next_index) return false;
            self.running_state.index = next_index;
            return true;
        }

        pub fn reset(self: *Self) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();

            if (self.running_state.index == 0) return false;
            self.running_state.index = 0;
            return true;
        }

        pub fn setCount(self: *Self, count: usize) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();

            const next_index = normalizeIndex(self.running_state.index, count);
            if (self.running_state.count == count and self.running_state.index == next_index) return false;
            self.running_state.count = count;
            self.running_state.index = next_index;
            return true;
        }

        pub fn setLoop(self: *Self, value: bool) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();

            if (self.running_state.loop == value) return false;
            self.running_state.loop = value;
            return true;
        }

        pub fn reduce(store: anytype, message: Message, emit: Emitter) !usize {
            _ = emit;

            return switch (message.body) {
                .ui_selection_next => if (store.next()) 1 else 0,
                .ui_selection_prev => if (store.prev()) 1 else 0,
                .ui_selection_set => |selection_event| if (store.set(selection_event.index)) 1 else 0,
                .ui_selection_reset => if (store.reset()) 1 else 0,
                .ui_selection_set_count => |selection_event| if (store.setCount(selection_event.count)) 1 else 0,
                .ui_selection_set_loop => |selection_event| if (store.setLoop(selection_event.value)) 1 else 0,
                else => 0,
            };
        }

        fn normalizeState(initial: State) State {
            var normalized = initial;
            normalized.index = normalizeIndex(initial.index, initial.count);
            return normalized;
        }

        fn normalizeIndex(index: usize, count: usize) usize {
            if (count == 0) return 0;
            return @min(index, count - 1);
        }

        fn nextLocked(state: *State) bool {
            if (state.count == 0) return false;
            if (state.index + 1 < state.count) {
                state.index += 1;
                return true;
            }
            if (!state.loop or state.index == 0) return false;
            state.index = 0;
            return true;
        }

        fn prevLocked(state: *State) bool {
            if (state.count == 0) return false;
            if (state.index > 0) {
                state.index -= 1;
                return true;
            }
            if (!state.loop or state.count <= 1) return false;
            state.index = state.count - 1;
            return true;
        }

        fn stateEql(a: State, b: State) bool {
            return a.index == b.index and
                a.count == b.count and
                a.loop == b.loop;
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const SelectionStore = make(lib);

    const TestCase = struct {
        fn next_prev_loop_and_tick_snapshot(testing: anytype, allocator: lib.mem.Allocator) !void {
            var selection = SelectionStore.init(allocator, .{
                .count = 3,
                .loop = true,
            });
            defer selection.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var noop = NoopSink{};
            const emit = Emitter.init(&noop);

            try testing.expectEqual(@as(usize, 0), selection.get().index);
            try testing.expectEqual(@as(usize, 3), selection.get().count);
            try testing.expectEqual(true, selection.get().loop);

            try testing.expectEqual(@as(usize, 1), try SelectionStore.reduce(&selection, .{
                .origin = .manual,
                .body = .{
                    .ui_selection_next = .{},
                },
            }, emit));

            try testing.expectEqual(@as(usize, 0), selection.get().index);
            selection.tick();
            try testing.expectEqual(@as(usize, 1), selection.get().index);

            try testing.expectEqual(@as(usize, 1), try SelectionStore.reduce(&selection, .{
                .origin = .manual,
                .body = .{
                    .ui_selection_next = .{},
                },
            }, emit));
            try testing.expectEqual(@as(usize, 1), try SelectionStore.reduce(&selection, .{
                .origin = .manual,
                .body = .{
                    .ui_selection_next = .{},
                },
            }, emit));
            selection.tick();

            try testing.expectEqual(@as(usize, 0), selection.get().index);

            try testing.expectEqual(@as(usize, 1), try SelectionStore.reduce(&selection, .{
                .origin = .manual,
                .body = .{
                    .ui_selection_prev = .{},
                },
            }, emit));
            selection.tick();

            try testing.expectEqual(@as(usize, 2), selection.get().index);
        }

        fn set_count_clamps_and_non_loop_edges_noop(testing: anytype, allocator: lib.mem.Allocator) !void {
            var selection = SelectionStore.init(allocator, .{
                .index = 4,
                .count = 5,
                .loop = true,
            });
            defer selection.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var noop = NoopSink{};
            const emit = Emitter.init(&noop);

            try testing.expectEqual(@as(usize, 4), selection.get().index);

            try testing.expectEqual(@as(usize, 1), try SelectionStore.reduce(&selection, .{
                .origin = .manual,
                .body = .{
                    .ui_selection_set_count = .{
                        .count = 2,
                    },
                },
            }, emit));
            selection.tick();

            try testing.expectEqual(@as(usize, 1), selection.get().index);
            try testing.expectEqual(@as(usize, 2), selection.get().count);

            try testing.expectEqual(@as(usize, 1), try SelectionStore.reduce(&selection, .{
                .origin = .manual,
                .body = .{
                    .ui_selection_set_loop = .{
                        .value = false,
                    },
                },
            }, emit));
            selection.tick();

            try testing.expectEqual(false, selection.get().loop);

            try testing.expectEqual(@as(usize, 0), try SelectionStore.reduce(&selection, .{
                .origin = .manual,
                .body = .{
                    .ui_selection_next = .{},
                },
            }, emit));
            selection.tick();
            try testing.expectEqual(@as(usize, 1), selection.get().index);

            try testing.expectEqual(@as(usize, 1), try SelectionStore.reduce(&selection, .{
                .origin = .manual,
                .body = .{
                    .ui_selection_reset = .{},
                },
            }, emit));
            selection.tick();

            try testing.expectEqual(@as(usize, 0), selection.get().index);

            try testing.expectEqual(@as(usize, 0), try SelectionStore.reduce(&selection, .{
                .origin = .manual,
                .body = .{
                    .ui_selection_prev = .{},
                },
            }, emit));
            selection.tick();
            try testing.expectEqual(@as(usize, 0), selection.get().index);
        }

        fn set_and_empty_count_normalize_as_expected(testing: anytype, allocator: lib.mem.Allocator) !void {
            var selection = SelectionStore.init(allocator, .{
                .index = 9,
                .count = 0,
                .loop = true,
            });
            defer selection.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var noop = NoopSink{};
            const emit = Emitter.init(&noop);

            try testing.expectEqual(@as(usize, 0), selection.get().index);
            try testing.expectEqual(@as(usize, 0), selection.get().count);

            try testing.expectEqual(@as(usize, 1), try SelectionStore.reduce(&selection, .{
                .origin = .manual,
                .body = .{
                    .ui_selection_set_count = .{
                        .count = 4,
                    },
                },
            }, emit));
            selection.tick();

            try testing.expectEqual(@as(usize, 0), selection.get().index);
            try testing.expectEqual(@as(usize, 4), selection.get().count);

            try testing.expectEqual(@as(usize, 1), try SelectionStore.reduce(&selection, .{
                .origin = .manual,
                .body = .{
                    .ui_selection_set = .{
                        .index = 99,
                    },
                },
            }, emit));
            selection.tick();

            try testing.expectEqual(@as(usize, 3), selection.get().index);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const testing = lib.testing;

            TestCase.next_prev_loop_and_tick_snapshot(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.set_count_clamps_and_non_loop_edges_noop(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.set_and_empty_count_normalize_as_expected(testing, allocator) catch |err| {
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
