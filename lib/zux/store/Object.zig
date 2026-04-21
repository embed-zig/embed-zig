const testing_api = @import("testing");
const Subscriber = @import("Subscriber.zig");

pub fn make(comptime lib: type, comptime T: type, comptime label: anytype) type {
    const Allocator = lib.mem.Allocator;
    const AtomicU64 = lib.atomic.Value(u64);
    const SubscriberList = lib.ArrayList(*Subscriber);
    const Mutex = lib.Thread.Mutex;
    const RwLock = lib.Thread.RwLock;
    const label_name = labelText(label);

    return struct {
        const Self = @This();

        pub const Lib = lib;
        pub const StateType = T;
        pub const Label = label_name;
        pub const Notification = Subscriber.Notification;

        pub const SubscribeError = error{OutOfMemory};

        allocator: Allocator,

        running_mu: Mutex = .{},
        running: T,

        released_mu: RwLock = .{},
        released: T,

        subscribers_mu: Mutex = .{},
        subscribers: SubscriberList = .empty,
        subscribers_notifying: bool = false,

        tick_count: AtomicU64 = AtomicU64.init(0),

        pub fn init(allocator: Allocator, initial: T) Self {
            return .{
                .allocator = allocator,
                .running = initial,
                .released = initial,
            };
        }

        pub fn deinit(self: *Self) void {
            self.subscribers_mu.lock();
            defer self.subscribers_mu.unlock();
            if (self.subscribers_notifying) {
                @panic("zux.store.Object.deinit cannot run during subscriber notification");
            }
            self.subscribers.deinit(self.allocator);
            self.subscribers = .empty;
        }

        pub fn set(self: *Self, value: T) void {
            self.running_mu.lock();
            defer self.running_mu.unlock();

            self.running = value;
        }

        pub fn invoke(self: *Self, arg: anytype, comptime func: *const fn (*T, @TypeOf(arg)) void) void {
            self.running_mu.lock();
            defer self.running_mu.unlock();

            func(&self.running, arg);
        }

        pub fn patch(self: *Self, value: anytype) void {
            self.running_mu.lock();
            defer self.running_mu.unlock();

            patchValue(&self.running, value);
        }

        pub fn get(self: *Self) T {
            self.released_mu.lockShared();
            defer self.released_mu.unlockShared();

            return self.released;
        }

        pub fn eql(self: *Self, expected: anytype) bool {
            const actual = self.get();
            const ExpectedType = @TypeOf(expected);
            if (ExpectedType == T) {
                return !diffValue(T, actual, expected);
            }

            switch (@typeInfo(T)) {
                .@"struct" => {
                    var expected_state: T = .{};
                    patchValue(&expected_state, expected);
                    return !diffValue(T, actual, expected_state);
                },
                else => @compileError("zux.store.Object.eql expects " ++ @typeName(T) ++ " for non-struct state"),
            }
        }

        pub fn tick(self: *Self) void {
            const tick_count = self.tick_count.fetchAdd(1, .acq_rel) + 1;
            self.running_mu.lock();
            self.released_mu.lock();

            if (!diffPtr(T, &self.released, &self.running)) {
                self.released_mu.unlock();
                self.running_mu.unlock();
                return;
            }

            self.released = self.running;
            self.released_mu.unlock();
            self.running_mu.unlock();

            self.subscribers_mu.lock();
            if (self.subscribers_notifying) {
                self.subscribers_mu.unlock();
                @panic("zux.store.Object.tick cannot reenter subscriber notification on the same object");
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
                    .label = Label,
                    .tick_count = tick_count,
                });
            }
        }

        pub fn subscribe(
            self: *Self,
            subscriber: *Subscriber,
        ) SubscribeError!void {
            self.subscribers_mu.lock();
            defer self.subscribers_mu.unlock();
            if (self.subscribers_notifying) {
                @panic("zux.store.Object.subscribe cannot mutate subscribers during notification");
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
                @panic("zux.store.Object.unsubscribe cannot mutate subscribers during notification");
            }

            for (self.subscribers.items, 0..) |existing, i| {
                if (existing != subscriber) continue;
                _ = self.subscribers.orderedRemove(i);
                return true;
            }

            return false;
        }
    };
}

fn labelText(comptime raw_label: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(raw_label))) {
        .enum_literal => @tagName(raw_label),
        .pointer => |ptr| switch (ptr.size) {
            .slice => raw_label,
            .one => switch (@typeInfo(ptr.child)) {
                .array => raw_label[0..],
                else => @compileError("zux.store.Object.make label must be enum_literal or []const u8"),
            },
            else => @compileError("zux.store.Object.make label must be enum_literal or []const u8"),
        },
        .array => raw_label[0..],
        else => @compileError("zux.store.Object.make label must be enum_literal or []const u8"),
    };
}

fn diffValue(comptime V: type, a: V, b: V) bool {
    return diffPtr(V, &a, &b);
}

fn diffPtr(comptime V: type, a: *const V, b: *const V) bool {
    return switch (@typeInfo(V)) {
        .void, .null => false,
        .bool,
        .int,
        .float,
        .comptime_int,
        .comptime_float,
        .@"enum",
        .error_set,
        => a.* != b.*,

        .optional => |info| {
            if (a.* == null and b.* == null) return false;
            if (a.* == null or b.* == null) return true;
            const av = a.*.?;
            const bv = b.*.?;
            return diffPtr(info.child, &av, &bv);
        },

        .array => |info| {
            for (0..a.*.len) |i| {
                if (diffPtr(info.child, &a.*[i], &b.*[i])) return true;
            }
            return false;
        },

        .vector => |info| {
            inline for (0..info.len) |i| {
                const av = a.*[i];
                const bv = b.*[i];
                if (diffPtr(info.child, &av, &bv)) return true;
            }
            return false;
        },

        .pointer => |info| switch (info.size) {
            .slice => {
                if (a.*.len != b.*.len) return true;
                for (a.*, 0..) |item, i| {
                    const bv = b.*[i];
                    if (diffPtr(info.child, &item, &bv)) return true;
                }
                return false;
            },
            else => @compileError("zux.StoreObject.diff does not support non-slice pointers in " ++ @typeName(V)),
        },

        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (diffPtr(field.type, &@field(a.*, field.name), &@field(b.*, field.name))) return true;
            }
            return false;
        },

        else => @compileError("zux.StoreObject.diff does not support " ++ @typeName(V)),
    };
}

fn patchValue(dst: anytype, src: anytype) void {
    const DstPtr = @TypeOf(dst);
    const ptr_info = @typeInfo(DstPtr);
    if (ptr_info != .pointer or ptr_info.pointer.size != .one) {
        @compileError("zux.StoreObject.patchValue expects a single-item destination pointer");
    }

    const Dst = ptr_info.pointer.child;
    const Src = @TypeOf(src);

    switch (@typeInfo(Dst)) {
        .@"struct" => |dst_info| {
            switch (@typeInfo(Src)) {
                .@"struct" => |src_info| {
                    _ = dst_info;
                    inline for (src_info.fields) |field| {
                        if (!@hasField(Dst, field.name)) {
                            @compileError("zux.StoreObject.patch unknown field '" ++ field.name ++ "' for " ++ @typeName(Dst));
                        }

                        patchValue(&@field(dst.*, field.name), @field(src, field.name));
                    }
                },
                else => {
                    assignPatchedValue(dst, src);
                },
            }
        },

        .array => {
            if (Dst != Src) {
                @compileError("zux.StoreObject.patch array type mismatch: cannot patch " ++ @typeName(Dst) ++ " with " ++ @typeName(Src));
            }
            dst.* = src;
        },

        else => {
            assignPatchedValue(dst, src);
        },
    }
}

fn assignPatchedValue(dst: anytype, src: anytype) void {
    const DstPtr = @TypeOf(dst);
    const ptr_info = @typeInfo(DstPtr);
    if (ptr_info != .pointer or ptr_info.pointer.size != .one) {
        @compileError("zux.StoreObject.assignPatchedValue expects a single-item destination pointer");
    }

    const Dst = ptr_info.pointer.child;
    const Src = @TypeOf(src);

    if (Dst == Src) {
        dst.* = src;
        return;
    }

    switch (@typeInfo(Dst)) {
        .int => switch (@typeInfo(Src)) {
            .comptime_int => {
                dst.* = @as(Dst, src);
                return;
            },
            else => {},
        },
        .float => switch (@typeInfo(Src)) {
            .comptime_float, .comptime_int => {
                dst.* = @as(Dst, src);
                return;
            },
            else => {},
        },
        .@"enum" => switch (@typeInfo(Src)) {
            .enum_literal => {
                dst.* = @as(Dst, src);
                return;
            },
            else => {},
        },
        else => {},
    }

    @compileError("zux.StoreObject.patch type mismatch: cannot patch " ++ @typeName(Dst) ++ " with " ++ @typeName(Src));
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const StoreLib = struct {
        pub const atomic = lib.atomic;
        pub const mem = lib.mem;
        pub const Thread = lib.Thread;
        pub const ArrayList = lib.ArrayList;
    };

    const TestCase = struct {
        fn diff_scalars_and_nested(testing: anytype, _: lib.mem.Allocator) !void {
            const S = make(StoreLib, struct {
                count: u32,
                enabled: bool,
                nested: struct {
                    ok: bool,
                },
            }, .test_diff_nested);

            const a: S.StateType = .{
                .count = 1,
                .enabled = true,
                .nested = .{ .ok = false },
            };
            const b: S.StateType = .{
                .count = 1,
                .enabled = true,
                .nested = .{ .ok = false },
            };
            const c: S.StateType = .{
                .count = 1,
                .enabled = true,
                .nested = .{ .ok = true },
            };

            try testing.expect(!diffValue(S.StateType, a, b));
            try testing.expect(diffValue(S.StateType, a, c));
        }

        fn diff_slices(testing: anytype, _: lib.mem.Allocator) !void {
            const S = make(StoreLib, struct {
                name: []const u8,
                data: []const u8,
            }, .test_diff_slices);

            const a: S.StateType = .{
                .name = "idy",
                .data = "abc",
            };
            const b: S.StateType = .{
                .name = "idy",
                .data = "abc",
            };
            const c: S.StateType = .{
                .name = "idy",
                .data = "abd",
            };

            try testing.expect(!diffValue(S.StateType, a, b));
            try testing.expect(diffValue(S.StateType, a, c));
        }

        fn set_write_then_tick(testing: anytype, allocator: lib.mem.Allocator) !void {
            const S = make(StoreLib, struct {
                count: u32,
                enabled: bool,
            }, .test_set);

            var state = S.init(allocator, .{
                .count = 1,
                .enabled = false,
            });
            defer state.deinit();

            try testing.expectEqual(@as(u32, 1), state.get().count);
            state.tick();
            try testing.expectEqual(@as(u32, 1), state.get().count);

            state.set(.{
                .count = 2,
                .enabled = true,
            });

            try testing.expectEqual(@as(u32, 1), state.get().count);

            state.tick();
            try testing.expectEqual(@as(u32, 2), state.get().count);
            try testing.expect(state.get().enabled);
        }

        fn eql_reads_released_state(testing: anytype, allocator: lib.mem.Allocator) !void {
            const S = make(StoreLib, struct {
                count: u32 = 0,
                enabled: bool = false,
            }, .test_eql);

            var state = S.init(allocator, .{});
            defer state.deinit();

            try testing.expect(state.eql(.{}));
            try testing.expect(!state.eql(.{
                .count = 1,
            }));

            state.set(.{
                .count = 1,
                .enabled = true,
            });

            try testing.expect(state.eql(.{}));

            state.tick();
            try testing.expect(state.eql(.{
                .count = 1,
                .enabled = true,
            }));
        }

        fn invoke_mutates_running_then_tick_publishes(testing: anytype, allocator: lib.mem.Allocator) !void {
            const S = make(StoreLib, struct {
                frame: [4]u8,
                brightness: u8,
            }, .test_invoke);
            const Arg = struct {
                second: u8,
                fourth: u8,
                brightness: u8,
            };

            var state = S.init(allocator, .{
                .frame = .{ 1, 2, 3, 4 },
                .brightness = 16,
            });
            defer state.deinit();

            state.invoke(Arg{
                .second = 9,
                .fourth = 7,
                .brightness = 128,
            }, struct {
                fn apply(running: *S.StateType, arg: Arg) void {
                    running.frame[1] = arg.second;
                    running.frame[3] = arg.fourth;
                    running.brightness = arg.brightness;
                }
            }.apply);

            const before_tick = state.get();
            try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, &before_tick.frame);
            try testing.expectEqual(@as(u8, 16), before_tick.brightness);

            state.tick();

            const after_tick = state.get();
            try testing.expectEqualSlices(u8, &[_]u8{ 1, 9, 3, 7 }, &after_tick.frame);
            try testing.expectEqual(@as(u8, 128), after_tick.brightness);
        }

        fn patch_merge_nested_and_replace_array(testing: anytype, allocator: lib.mem.Allocator) !void {
            const S = make(StoreLib, struct {
                count: u32,
                nested: struct {
                    enabled: bool,
                    name: []const u8,
                },
                values: [3]u8,
            }, .test_patch);

            var state = S.init(allocator, .{
                .count = 1,
                .nested = .{
                    .enabled = false,
                    .name = "old",
                },
                .values = .{ 1, 2, 3 },
            });
            defer state.deinit();

            state.patch(.{
                .nested = .{
                    .enabled = true,
                },
                .values = [_]u8{ 7, 8, 9 },
            });

            try testing.expectEqual(@as(bool, false), state.get().nested.enabled);
            try testing.expectEqualStrings("old", state.get().nested.name);
            try testing.expectEqual(@as(u8, 1), state.get().values[0]);

            state.tick();

            const snapshot = state.get();
            try testing.expect(snapshot.nested.enabled);
            try testing.expectEqualStrings("old", snapshot.nested.name);
            try testing.expectEqualSlices(u8, &.{ 7, 8, 9 }, &snapshot.values);
        }

        fn subscribe_add_and_remove_subscriber(testing: anytype, allocator: lib.mem.Allocator) !void {
            const S = make(StoreLib, struct {
                value: u32,
            }, .test_subscriptions);

            const Impl = struct {
                pub fn notify(_: *@This(), _: Subscriber.Notification) void {}
            };

            var state = S.init(allocator, .{ .value = 1 });
            defer state.deinit();

            var impl = Impl{};
            var subscriber = Subscriber.init(&impl);

            try state.subscribe(&subscriber);
            try state.subscribe(&subscriber);
            try testing.expectEqual(@as(usize, 1), state.subscribers.items.len);

            try testing.expect(state.unsubscribe(&subscriber));
            try testing.expectEqual(@as(usize, 0), state.subscribers.items.len);
            try testing.expect(!state.unsubscribe(&subscriber));
        }

        fn tick_notify_subscribers_with_label(testing: anytype, allocator: lib.mem.Allocator) !void {
            const S = make(StoreLib, struct {
                value: u32,
            }, .app_session);

            const Impl = struct {
                called: bool = false,
                label: []const u8 = "",
                tick_count: u64 = 0,

                pub fn notify(self: *@This(), notification: Subscriber.Notification) void {
                    self.called = true;
                    self.label = notification.label;
                    self.tick_count = notification.tick_count;
                }
            };

            var state = S.init(allocator, .{ .value = 1 });
            defer state.deinit();

            var impl = Impl{};
            var subscriber = Subscriber.init(&impl);
            try state.subscribe(&subscriber);

            state.set(.{ .value = 2 });
            state.tick();

            try testing.expect(impl.called);
            try testing.expectEqualStrings("app_session", impl.label);
            try testing.expectEqual(@as(u64, 1), impl.tick_count);
            try testing.expectEqual(@as(u32, 2), state.get().value);
        }

        fn tick_noop_does_not_notify_but_advances_tick_count(testing: anytype, allocator: lib.mem.Allocator) !void {
            const S = make(StoreLib, struct {
                value: u32,
            }, .tick_noop);

            const Impl = struct {
                called: bool = false,
                tick_count: u64 = 0,

                pub fn notify(self: *@This(), notification: Subscriber.Notification) void {
                    self.called = true;
                    self.tick_count = notification.tick_count;
                }
            };

            var state = S.init(allocator, .{ .value = 1 });
            defer state.deinit();

            var impl = Impl{};
            var subscriber = Subscriber.init(&impl);
            try state.subscribe(&subscriber);

            state.tick();

            try testing.expectEqual(@as(u64, 1), state.tick_count.load(.acquire));
            try testing.expect(!impl.called);
            try testing.expectEqual(@as(u64, 0), impl.tick_count);

            state.set(.{ .value = 2 });
            state.tick();

            try testing.expectEqual(@as(u64, 2), state.tick_count.load(.acquire));
            try testing.expect(impl.called);
            try testing.expectEqual(@as(u64, 2), impl.tick_count);
        }

        fn tick_notifies_multiple_subscribers_once_each(testing: anytype, allocator: lib.mem.Allocator) !void {
            const S = make(StoreLib, struct {
                value: u32,
            }, .multi_subscriber);

            const Impl = struct {
                calls: usize = 0,
                last_tick_count: u64 = 0,

                pub fn notify(self: *@This(), notification: Subscriber.Notification) void {
                    self.calls += 1;
                    self.last_tick_count = notification.tick_count;
                }
            };

            var state = S.init(allocator, .{ .value = 1 });
            defer state.deinit();

            var a = Impl{};
            var b = Impl{};
            var subscriber_a = Subscriber.init(&a);
            var subscriber_b = Subscriber.init(&b);
            try state.subscribe(&subscriber_a);
            try state.subscribe(&subscriber_b);

            state.set(.{ .value = 2 });
            state.tick();

            try testing.expectEqual(@as(usize, 1), a.calls);
            try testing.expectEqual(@as(usize, 1), b.calls);
            try testing.expectEqual(@as(u64, 1), a.last_tick_count);
            try testing.expectEqual(@as(u64, 1), b.last_tick_count);

            state.tick();

            try testing.expectEqual(@as(usize, 1), a.calls);
            try testing.expectEqual(@as(usize, 1), b.calls);

            state.set(.{ .value = 3 });
            state.tick();

            try testing.expectEqual(@as(usize, 2), a.calls);
            try testing.expectEqual(@as(usize, 2), b.calls);
            try testing.expectEqual(@as(u64, 3), a.last_tick_count);
            try testing.expectEqual(@as(u64, 3), b.last_tick_count);
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

            TestCase.diff_scalars_and_nested(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.diff_slices(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.set_write_then_tick(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.eql_reads_released_state(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.invoke_mutates_running_then_tick_publishes(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.patch_merge_nested_and_replace_array(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.subscribe_add_and_remove_subscriber(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.tick_notify_subscribers_with_label(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.tick_noop_does_not_notify_but_advances_tick_count(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.tick_notifies_multiple_subscribers_once_each(testing, allocator) catch |err| {
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
