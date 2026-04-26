const glib = @import("glib");

const Emitter = @import("../../../pipeline/Emitter.zig");
const Message = @import("../../../pipeline/Message.zig");
const Subscriber = @import("../../../store/Subscriber.zig");
const Router = @import("Router.zig");
const State = @import("State.zig");

pub fn make(comptime grt: type) type {
    const AtomicU64 = grt.std.atomic.Value(u64);
    const Mutex = grt.std.Thread.Mutex;
    const SubscriberList = grt.std.ArrayList(*Subscriber);
    const Item = Router.Item;
    const RouterImpl = Router.make(grt);

    return struct {
        const Self = @This();

        pub const Error = RouterImpl.Error;
        pub const StateType = State;
        pub const ItemType = Item;

        allocator: glib.std.mem.Allocator,
        router_impl: RouterImpl,

        subscribers_mu: Mutex = .{},
        subscribers: SubscriberList = .empty,
        subscribers_notifying: bool = false,
        tick_count: AtomicU64 = AtomicU64.init(0),

        pub fn init(allocator: glib.std.mem.Allocator, initial: Item) Error!Self {
            return .{
                .allocator = allocator,
                .router_impl = try RouterImpl.init(allocator, initial),
            };
        }

        pub fn deinit(self: *Self) void {
            self.subscribers_mu.lock();
            if (self.subscribers_notifying) {
                self.subscribers_mu.unlock();
                @panic("zux.component.ui.route.deinit cannot run during subscriber notification");
            }
            self.subscribers.deinit(self.allocator);
            self.subscribers = .empty;
            self.subscribers_mu.unlock();

            self.router_impl.deinit();
        }

        pub fn get(self: *Self) State {
            return self.router_impl.state();
        }

        pub fn router(self: *Self) Router {
            return self.router_impl.handle();
        }

        pub fn subscribe(self: *Self, subscriber: *Subscriber) error{OutOfMemory}!void {
            self.subscribers_mu.lock();
            defer self.subscribers_mu.unlock();
            if (self.subscribers_notifying) {
                @panic("zux.component.ui.route.subscribe cannot mutate subscribers during notification");
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
                @panic("zux.component.ui.route.unsubscribe cannot mutate subscribers during notification");
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
            const changed = self.router_impl.tick();
            if (!changed) return;

            self.subscribers_mu.lock();
            if (self.subscribers_notifying) {
                self.subscribers_mu.unlock();
                @panic("zux.component.ui.route.tick cannot reenter subscriber notification");
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
                    .label = "ui_route",
                    .tick_count = tick_count,
                });
            }
        }

        pub fn push(self: *Self, next_item: Item) Error!bool {
            return self.router_impl.push(next_item);
        }

        pub fn replace(self: *Self, next_item: Item) bool {
            return self.router_impl.replace(next_item);
        }

        pub fn reset(self: *Self, next_item: Item) bool {
            return self.router_impl.reset(next_item);
        }

        pub fn pop(self: *Self) bool {
            return self.router_impl.pop();
        }

        pub fn popToRoot(self: *Self) bool {
            return self.router_impl.popToRoot();
        }

        pub fn setTransitioning(self: *Self, value: bool) bool {
            return self.router_impl.setTransitioning(value);
        }

        pub fn reduce(store: anytype, message: Message, emit: Emitter) !usize {
            _ = emit;

            return switch (message.body) {
                .ui_route_push => |route_event| if (try store.push(route_event.item)) 1 else 0,
                .ui_route_replace => |route_event| if (store.replace(route_event.item)) 1 else 0,
                .ui_route_reset => |route_event| if (store.reset(route_event.item)) 1 else 0,
                .ui_route_pop => if (store.pop()) 1 else 0,
                .ui_route_pop_to_root => if (store.popToRoot()) 1 else 0,
                .ui_route_set_transitioning => |route_event| if (store.setTransitioning(route_event.value)) 1 else 0,
                else => 0,
            };
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const RouteStore = make(grt);

    const TestCase = struct {
        fn reduce_updates_version_and_router_snapshot(allocator: glib.std.mem.Allocator) !void {
            var route = try RouteStore.init(allocator, .{
                .screen_id = 1,
            });
            defer route.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var noop = NoopSink{};
            const emit = Emitter.init(&noop);

            try grt.std.testing.expectEqual(@as(u64, 0), route.get().version);
            try grt.std.testing.expectEqual(@as(u32, 1), route.get().current_page);
            try grt.std.testing.expectEqual(false, route.get().transitioning);

            try grt.std.testing.expectEqual(@as(usize, 1), try RouteStore.reduce(&route, .{
                .origin = .manual,
                .body = .{
                    .ui_route_push = .{
                        .item = .{ .screen_id = 2, .arg0 = 7 },
                    },
                },
            }, emit));

            try grt.std.testing.expectEqual(@as(u64, 0), route.get().version);
            route.tick();

            const state = route.get();
            const router = route.router();
            try grt.std.testing.expectEqual(@as(u64, 1), state.version);
            try grt.std.testing.expectEqual(@as(u32, 2), state.current_page);
            try grt.std.testing.expectEqual(false, state.transitioning);
            try grt.std.testing.expectEqual(@as(u64, 1), router.version());
            try grt.std.testing.expectEqual(@as(u32, 2), router.currentPage());
            try grt.std.testing.expectEqual(@as(usize, 2), router.depth());
            try grt.std.testing.expectEqual(@as(u32, 1), router.item(0).?.screen_id);
            try grt.std.testing.expectEqual(@as(u32, 2), router.item(1).?.screen_id);
            try grt.std.testing.expectEqual(@as(u32, 7), router.item(1).?.arg0);

            try grt.std.testing.expectEqual(@as(usize, 1), try RouteStore.reduce(&route, .{
                .origin = .manual,
                .body = .{
                    .ui_route_set_transitioning = .{
                        .value = true,
                    },
                },
            }, emit));
            route.tick();
            try grt.std.testing.expect(route.get().transitioning);
            try grt.std.testing.expect(route.router().transitioning());

            try grt.std.testing.expectEqual(@as(usize, 1), try RouteStore.reduce(&route, .{
                .origin = .manual,
                .body = .{
                    .ui_route_replace = .{
                        .item = .{ .screen_id = 3, .arg1 = 9 },
                    },
                },
            }, emit));
            route.tick();

            const replaced = route.router();
            try grt.std.testing.expectEqual(@as(u32, 3), route.get().current_page);
            try grt.std.testing.expect(route.get().transitioning);
            try grt.std.testing.expectEqual(@as(u32, 1), replaced.item(0).?.screen_id);
            try grt.std.testing.expectEqual(@as(u32, 3), replaced.item(1).?.screen_id);
            try grt.std.testing.expectEqual(@as(u32, 9), replaced.item(1).?.arg1);

            try grt.std.testing.expectEqual(@as(usize, 1), try RouteStore.reduce(&route, .{
                .origin = .manual,
                .body = .{
                    .ui_route_pop = .{},
                },
            }, emit));
            route.tick();

            try grt.std.testing.expectEqual(@as(u32, 1), route.get().current_page);
            try grt.std.testing.expect(route.get().transitioning);
            try grt.std.testing.expectEqual(@as(usize, 1), route.router().depth());
        }

        fn pop_to_root_and_noop_tick_behave_as_expected(allocator: glib.std.mem.Allocator) !void {
            var route = try RouteStore.init(allocator, .{
                .screen_id = 10,
            });
            defer route.deinit();

            try grt.std.testing.expect(try route.push(.{ .screen_id = 11 }));
            try grt.std.testing.expect(try route.push(.{ .screen_id = 12 }));
            try grt.std.testing.expect(try route.push(.{ .screen_id = 13 }));
            route.tick();

            try grt.std.testing.expectEqual(@as(usize, 4), route.router().depth());
            try grt.std.testing.expectEqual(false, route.get().transitioning);
            try grt.std.testing.expect(route.popToRoot());
            route.tick();

            try grt.std.testing.expectEqual(@as(usize, 1), route.router().depth());
            try grt.std.testing.expectEqual(@as(u32, 10), route.router().item(0).?.screen_id);
            try grt.std.testing.expectEqual(false, route.get().transitioning);

            const version = route.get().version;
            route.tick();
            try grt.std.testing.expectEqual(version, route.get().version);
            try grt.std.testing.expect(!route.pop());
        }

        fn push_supports_dynamic_depth(allocator: glib.std.mem.Allocator) !void {
            var route = try RouteStore.init(allocator, .{
                .screen_id = 20,
            });
            defer route.deinit();

            var i: u32 = 0;
            while (i < 16) : (i += 1) {
                try grt.std.testing.expect(try route.push(.{ .screen_id = 21 + i }));
            }
            route.tick();

            try grt.std.testing.expectEqual(@as(usize, 17), route.router().depth());
            try grt.std.testing.expectEqual(@as(u32, 36), route.get().current_page);
            try grt.std.testing.expectEqual(false, route.get().transitioning);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.reduce_updates_version_and_router_snapshot(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.pop_to_root_and_noop_tick_behave_as_expected(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.push_supports_dynamic_depth(allocator) catch |err| {
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
