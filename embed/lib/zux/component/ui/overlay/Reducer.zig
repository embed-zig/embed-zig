const glib = @import("glib");

const Emitter = @import("../../../pipeline/Emitter.zig");
const Message = @import("../../../pipeline/Message.zig");
const Subscriber = @import("../../../store/Subscriber.zig");
const State = @import("State.zig");

pub fn make(comptime grt: type) type {
    const AtomicU64 = grt.std.atomic.Value(u64);
    const Mutex = grt.std.Thread.Mutex;
    const RwLock = grt.std.Thread.RwLock;
    const SubscriberList = grt.std.ArrayList(*Subscriber);

    return struct {
        const Self = @This();

        pub const StateType = State;

        allocator: glib.std.mem.Allocator,

        running_mu: Mutex = .{},
        running_state: State = .{},

        released_mu: RwLock = .{},
        released_state: State = .{},

        subscribers_mu: Mutex = .{},
        subscribers: SubscriberList = .empty,
        subscribers_notifying: bool = false,
        tick_count: AtomicU64 = AtomicU64.init(0),

        pub fn init(allocator: glib.std.mem.Allocator, initial: State) Self {
            return .{
                .allocator = allocator,
                .running_state = initial,
                .released_state = initial,
            };
        }

        pub fn deinit(self: *Self) void {
            self.subscribers_mu.lock();
            if (self.subscribers_notifying) {
                self.subscribers_mu.unlock();
                @panic("zux.component.ui.overlay.deinit cannot run during subscriber notification");
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
                @panic("zux.component.ui.overlay.subscribe cannot mutate subscribers during notification");
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
                @panic("zux.component.ui.overlay.unsubscribe cannot mutate subscribers during notification");
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
                @panic("zux.component.ui.overlay.tick cannot reenter subscriber notification");
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
                    .label = "ui_overlay",
                    .tick_count = tick_count,
                });
            }
        }

        pub fn show(self: *Self, name_fields: State.NameFields, blocking: bool) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();

            const name_changed = self.running_state.setNameFields(name_fields);
            if (self.running_state.visible and !name_changed and self.running_state.blocking == blocking) {
                return false;
            }

            self.running_state.visible = true;
            self.running_state.blocking = blocking;
            return true;
        }

        pub fn hide(self: *Self) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();

            if (!self.running_state.visible) return false;
            self.running_state.visible = false;
            return true;
        }

        pub fn setName(self: *Self, name_fields: State.NameFields) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();

            return self.running_state.setNameFields(name_fields);
        }

        pub fn setBlocking(self: *Self, value: bool) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();

            if (self.running_state.blocking == value) return false;
            self.running_state.blocking = value;
            return true;
        }

        pub fn reduce(store: anytype, message: Message, emit: Emitter) !usize {
            _ = emit;

            return switch (message.body) {
                .ui_overlay_show => |overlay_event| if (store.show(try eventNameFields(overlay_event), overlay_event.blocking)) 1 else 0,
                .ui_overlay_hide => if (store.hide()) 1 else 0,
                .ui_overlay_set_name => |overlay_event| if (store.setName(try eventNameFields(overlay_event))) 1 else 0,
                .ui_overlay_set_blocking => |overlay_event| if (store.setBlocking(overlay_event.value)) 1 else 0,
                else => 0,
            };
        }

        fn stateEql(a: State, b: State) bool {
            return a.visible == b.visible and
                a.name_len == b.name_len and
                grt.std.mem.eql(u8, a.name[0..], b.name[0..]) and
                a.blocking == b.blocking;
        }

        fn eventNameFields(event: anytype) State.Error!State.NameFields {
            if (@as(usize, event.name_len) > State.max_name_len) {
                return error.NameTooLong;
            }
            return .{
                .name = event.name,
                .name_len = event.name_len,
            };
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const OverlayStore = make(grt);

    const TestCase = struct {
        fn show_hide_and_patch_fields(allocator: glib.std.mem.Allocator) !void {
            var overlay = OverlayStore.init(allocator, .{});
            defer overlay.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var noop = NoopSink{};
            const emit = Emitter.init(&noop);
            const loading_name = try State.nameFields("loading");
            const popup_name = try State.nameFields("popup");

            {
                const state = overlay.get();
                try grt.std.testing.expectEqual(false, state.visible);
                try grt.std.testing.expect(grt.std.mem.eql(u8, state.nameSlice(), ""));
                try grt.std.testing.expectEqual(false, state.blocking);
            }

            const show_message: Message = .{
                .origin = .manual,
                .body = .{
                    .ui_overlay_show = .{
                        .name = loading_name.name,
                        .name_len = loading_name.name_len,
                        .blocking = true,
                    },
                },
            };
            try grt.std.testing.expectEqual(@as(usize, 1), try OverlayStore.reduce(&overlay, show_message, emit));

            {
                const state = overlay.get();
                try grt.std.testing.expectEqual(false, state.visible);
            }
            overlay.tick();
            {
                const state = overlay.get();
                try grt.std.testing.expectEqual(true, state.visible);
                try grt.std.testing.expect(grt.std.mem.eql(u8, state.nameSlice(), "loading"));
                try grt.std.testing.expectEqual(true, state.blocking);
            }

            try grt.std.testing.expectEqual(@as(usize, 1), try OverlayStore.reduce(&overlay, .{
                .origin = .manual,
                .body = .{
                    .ui_overlay_set_blocking = .{
                        .value = false,
                    },
                },
            }, emit));
            overlay.tick();
            {
                const state = overlay.get();
                try grt.std.testing.expectEqual(false, state.blocking);
            }

            try grt.std.testing.expectEqual(@as(usize, 1), try OverlayStore.reduce(&overlay, .{
                .origin = .manual,
                .body = .{
                    .ui_overlay_set_name = .{
                        .name = popup_name.name,
                        .name_len = popup_name.name_len,
                    },
                },
            }, emit));
            overlay.tick();
            {
                const state = overlay.get();
                try grt.std.testing.expect(grt.std.mem.eql(u8, state.nameSlice(), "popup"));
            }

            try grt.std.testing.expectEqual(@as(usize, 1), try OverlayStore.reduce(&overlay, .{
                .origin = .manual,
                .body = .{
                    .ui_overlay_hide = .{},
                },
            }, emit));
            overlay.tick();
            {
                const state = overlay.get();
                try grt.std.testing.expectEqual(false, state.visible);
                try grt.std.testing.expect(grt.std.mem.eql(u8, state.nameSlice(), "popup"));
                try grt.std.testing.expectEqual(false, state.blocking);
            }
        }

        fn noops_do_not_dirty_state(allocator: glib.std.mem.Allocator) !void {
            var initial: State = .{
                .visible = true,
                .blocking = true,
            };
            try grt.std.testing.expect(try initial.setName("popup"));

            var overlay = OverlayStore.init(allocator, initial);
            defer overlay.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var noop = NoopSink{};
            const emit = Emitter.init(&noop);
            const popup_name = try State.nameFields("popup");

            try grt.std.testing.expectEqual(@as(usize, 0), try OverlayStore.reduce(&overlay, .{
                .origin = .manual,
                .body = .{
                    .ui_overlay_show = .{
                        .name = popup_name.name,
                        .name_len = popup_name.name_len,
                        .blocking = true,
                    },
                },
            }, emit));

            try grt.std.testing.expectEqual(@as(usize, 0), try OverlayStore.reduce(&overlay, .{
                .origin = .manual,
                .body = .{
                    .ui_overlay_set_name = .{
                        .name = popup_name.name,
                        .name_len = popup_name.name_len,
                    },
                },
            }, emit));

            try grt.std.testing.expectEqual(@as(usize, 0), try OverlayStore.reduce(&overlay, .{
                .origin = .manual,
                .body = .{
                    .ui_overlay_set_blocking = .{
                        .value = true,
                    },
                },
            }, emit));
        }

        fn too_long_name_returns_error(allocator: glib.std.mem.Allocator) !void {
            _ = allocator;
            var state: State = .{};
            const too_long_name = [_]u8{'x'} ** (State.max_name_len + 1);
            _ = state.setName(too_long_name[0..]) catch |err| {
                try grt.std.testing.expect(err == error.NameTooLong);
                try grt.std.testing.expect(grt.std.mem.eql(u8, state.nameSlice(), ""));
                return;
            };

            return error.ExpectedNameTooLong;
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.show_hide_and_patch_fields(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.noops_do_not_dirty_state(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.too_long_name_returns_error(allocator) catch |err| {
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
