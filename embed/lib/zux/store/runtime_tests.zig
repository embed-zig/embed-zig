const glib = @import("glib");
const StoreObject = @import("Object.zig");
const Subscriber = @import("Subscriber.zig");
const StoreBuilder = @import("Builder.zig");

const DefaultBuilder = StoreBuilder.Builder(.{});

fn makeTestStore(comptime store_lib: type, comptime configure: *const fn (*DefaultBuilder) void) type {
    var builder = DefaultBuilder.init();
    configure(&builder);
    return builder.make(store_lib);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn make_exposes_generated_Stores_type(allocator: glib.std.mem.Allocator) !void {
            const Wifi = struct { value: u32 };
            const Cellular = struct { enabled: bool };

            const S = makeTestStore(grt, struct {
                fn apply(builder: *DefaultBuilder) void {
                    builder.setStore(.wifi, Wifi);
                    builder.setStore(.cellular, Cellular);
                }
            }.apply);

            const stores: S.Stores = .{
                .wifi = .{ .value = 1 },
                .cellular = .{ .enabled = false },
            };

            var store = try S.init(allocator, stores);
            defer store.deinit();
            try grt.std.testing.expectEqual(@as(u32, 1), store.stores.wifi.value);
            try grt.std.testing.expect(!store.stores.cellular.enabled);
        }

        fn make_exposes_generated_State_type(_: glib.std.mem.Allocator) !void {
            const Wifi = struct { value: u32 };
            const Cellular = struct { enabled: bool };

            const S = makeTestStore(grt, struct {
                fn apply(builder: *DefaultBuilder) void {
                    builder.setStore(.wifi, Wifi);
                    builder.setStore(.cellular, Cellular);
                    builder.setState("ui", .{ .wifi, .cellular });
                    builder.setState("ui/home", .{.wifi});
                }
            }.apply);

            try grt.std.testing.expect(@hasField(S.State, "dirty"));
            try grt.std.testing.expect(@hasField(S.State, "handlers"));
            try grt.std.testing.expect(@hasField(S.State, "ui"));
            try grt.std.testing.expect(@hasField(@FieldType(S.State, "ui"), "home"));
        }

        fn make_initializes_internal_state_and_node_subscriber(allocator: glib.std.mem.Allocator) !void {
            const Wifi = struct { value: u32 };

            const S = makeTestStore(grt, struct {
                fn apply(builder: *DefaultBuilder) void {
                    builder.setStore(.wifi, Wifi);
                    builder.setState("ui", .{});
                }
            }.apply);

            const stores: S.Stores = .{
                .wifi = .{ .value = 9 },
            };

            var store = try S.init(allocator, stores);
            defer store.deinit();

            try grt.std.testing.expect(!store.state.dirty.load(.acquire));
            try grt.std.testing.expect(!store.state.ui.dirty.load(.acquire));

            store.state.ui.subscriber.notify(.{
                .label = "wifi",
                .tick_count = 1,
            });

            try grt.std.testing.expect(store.state.dirty.load(.acquire));
            try grt.std.testing.expect(store.state.ui.dirty.load(.acquire));
        }

        fn tick_runs_dirty_handlers_and_clears_flags(allocator: glib.std.mem.Allocator) !void {
            const Wifi = struct { value: u32 };

            const S = makeTestStore(grt, struct {
                fn apply(builder: *DefaultBuilder) void {
                    builder.setStore(.wifi, Wifi);
                    builder.setState("ui/home", .{});
                }
            }.apply);

            const Recorder = struct {
                var root_calls: usize = 0;
                var ui_calls: usize = 0;
                var home_calls: usize = 0;

                pub fn onRoot(_: *S.Stores) void {
                    root_calls += 1;
                }

                pub fn onUi(_: *S.Stores) void {
                    ui_calls += 1;
                }

                pub fn onHome(_: *S.Stores) void {
                    home_calls += 1;
                }
            };

            Recorder.root_calls = 0;
            Recorder.ui_calls = 0;
            Recorder.home_calls = 0;

            var store = try S.init(allocator, .{
                .wifi = .{ .value = 1 },
            });
            defer store.deinit();

            try store.handle("/", Recorder.onRoot);
            try store.handle("ui", Recorder.onUi);
            try store.handle("ui/home", Recorder.onHome);

            store.state.ui.home.subscriber.notify(.{
                .label = "wifi",
                .tick_count = 1,
            });

            try grt.std.testing.expect(store.state.dirty.load(.acquire));
            try grt.std.testing.expect(store.state.ui.dirty.load(.acquire));
            try grt.std.testing.expect(store.state.ui.home.dirty.load(.acquire));

            store.tick();

            try grt.std.testing.expectEqual(@as(usize, 1), Recorder.root_calls);
            try grt.std.testing.expectEqual(@as(usize, 1), Recorder.ui_calls);
            try grt.std.testing.expectEqual(@as(usize, 1), Recorder.home_calls);
            try grt.std.testing.expect(!store.state.dirty.load(.acquire));
            try grt.std.testing.expect(!store.state.ui.dirty.load(.acquire));
            try grt.std.testing.expect(!store.state.ui.home.dirty.load(.acquire));

            store.tick();

            try grt.std.testing.expectEqual(@as(usize, 1), Recorder.root_calls);
            try grt.std.testing.expectEqual(@as(usize, 1), Recorder.ui_calls);
            try grt.std.testing.expectEqual(@as(usize, 1), Recorder.home_calls);
        }

        fn tick_runs_parent_handler_for_bound_storeobject(allocator: glib.std.mem.Allocator) !void {
            const WifiStore = StoreObject.make(grt, struct {
                enabled: bool,
            }, .wifi);

            const S = makeTestStore(grt, struct {
                fn apply(builder: *DefaultBuilder) void {
                    builder.setStore(.wifi, WifiStore);
                    builder.setState("ui", .{.wifi});
                }
            }.apply);

            const Recorder = struct {
                var calls: usize = 0;

                pub fn onUi(_: *S.Stores) void {
                    calls += 1;
                }
            };

            Recorder.calls = 0;

            const wifi = WifiStore.init(allocator, .{
                .enabled = false,
            });
            var store = try S.init(allocator, .{
                .wifi = wifi,
            });
            defer store.stores.wifi.deinit();
            defer store.deinit();

            try store.handle("ui", Recorder.onUi);

            store.stores.wifi.set(.{ .enabled = true });
            store.tick();

            try grt.std.testing.expectEqual(@as(usize, 1), Recorder.calls);
            try grt.std.testing.expect(!store.state.dirty.load(.acquire));
            try grt.std.testing.expect(!store.state.ui.dirty.load(.acquire));
        }

        fn tick_runs_ancestor_handlers_without_clean_child_handlers(allocator: glib.std.mem.Allocator) !void {
            const Wifi = struct { value: u32 };

            const S = makeTestStore(grt, struct {
                fn apply(builder: *DefaultBuilder) void {
                    builder.setStore(.wifi, Wifi);
                    builder.setState("ui/home", .{});
                }
            }.apply);

            const Recorder = struct {
                var root_calls: usize = 0;
                var ui_calls: usize = 0;
                var home_calls: usize = 0;

                pub fn onRoot(_: *S.Stores) void {
                    root_calls += 1;
                }

                pub fn onUi(_: *S.Stores) void {
                    ui_calls += 1;
                }

                pub fn onHome(_: *S.Stores) void {
                    home_calls += 1;
                }
            };

            Recorder.root_calls = 0;
            Recorder.ui_calls = 0;
            Recorder.home_calls = 0;

            var store = try S.init(allocator, .{
                .wifi = .{ .value = 1 },
            });
            defer store.deinit();

            try store.handle("/", Recorder.onRoot);
            try store.handle("ui", Recorder.onUi);
            try store.handle("ui/home", Recorder.onHome);

            store.state.ui.subscriber.notify(.{
                .label = "wifi",
                .tick_count = 1,
            });

            try grt.std.testing.expect(store.state.dirty.load(.acquire));
            try grt.std.testing.expect(store.state.ui.dirty.load(.acquire));
            try grt.std.testing.expect(!store.state.ui.home.dirty.load(.acquire));

            store.tick();

            try grt.std.testing.expectEqual(@as(usize, 1), Recorder.root_calls);
            try grt.std.testing.expectEqual(@as(usize, 1), Recorder.ui_calls);
            try grt.std.testing.expectEqual(@as(usize, 0), Recorder.home_calls);
            try grt.std.testing.expect(!store.state.dirty.load(.acquire));
            try grt.std.testing.expect(!store.state.ui.dirty.load(.acquire));
            try grt.std.testing.expect(!store.state.ui.home.dirty.load(.acquire));
        }

        fn unhandle_prevents_future_tick_notifications(allocator: glib.std.mem.Allocator) !void {
            const Wifi = struct { value: u32 };

            const S = makeTestStore(grt, struct {
                fn apply(builder: *DefaultBuilder) void {
                    builder.setStore(.wifi, Wifi);
                    builder.setState("ui/home", .{});
                }
            }.apply);

            const Recorder = struct {
                var calls: usize = 0;

                pub fn onHome(_: *S.Stores) void {
                    calls += 1;
                }
            };

            Recorder.calls = 0;

            var store = try S.init(allocator, .{
                .wifi = .{ .value = 1 },
            });
            defer store.deinit();

            try store.handle("ui/home", Recorder.onHome);

            store.state.ui.home.subscriber.notify(.{
                .label = "wifi",
                .tick_count = 1,
            });
            store.tick();

            try grt.std.testing.expectEqual(@as(usize, 1), Recorder.calls);
            try grt.std.testing.expect(store.unhandle("ui/home", Recorder.onHome));

            store.state.ui.home.subscriber.notify(.{
                .label = "wifi",
                .tick_count = 2,
            });
            store.tick();

            try grt.std.testing.expectEqual(@as(usize, 1), Recorder.calls);
        }

        fn init_unbinds_partial_bindings_on_failure(allocator: glib.std.mem.Allocator) !void {
            const WifiStore = struct {
                pub var subscribe_calls: usize = 0;
                pub var unsubscribe_calls: usize = 0;
                pub var live_subscriptions: usize = 0;

                pub fn subscribe(_: *@This(), _: *Subscriber) error{OutOfMemory}!void {
                    subscribe_calls += 1;
                    live_subscriptions += 1;
                }

                pub fn unsubscribe(_: *@This(), _: *Subscriber) bool {
                    unsubscribe_calls += 1;
                    if (live_subscriptions == 0) return false;
                    live_subscriptions -= 1;
                    return true;
                }
            };

            const CellularStore = struct {
                pub var subscribe_calls: usize = 0;
                pub var unsubscribe_calls: usize = 0;

                pub fn subscribe(_: *@This(), _: *Subscriber) error{OutOfMemory}!void {
                    subscribe_calls += 1;
                    return error.OutOfMemory;
                }

                pub fn unsubscribe(_: *@This(), _: *Subscriber) bool {
                    unsubscribe_calls += 1;
                    return false;
                }
            };

            const S = makeTestStore(grt, struct {
                fn apply(builder: *DefaultBuilder) void {
                    builder.setStore(.wifi, WifiStore);
                    builder.setStore(.cellular, CellularStore);
                    builder.setState("ui", .{ .wifi, .cellular });
                }
            }.apply);

            WifiStore.subscribe_calls = 0;
            WifiStore.unsubscribe_calls = 0;
            WifiStore.live_subscriptions = 0;
            CellularStore.subscribe_calls = 0;
            CellularStore.unsubscribe_calls = 0;

            const stores: S.Stores = .{
                .wifi = .{},
                .cellular = .{},
            };

            try grt.std.testing.expectError(error.OutOfMemory, S.init(allocator, stores));
            try grt.std.testing.expectEqual(@as(usize, 1), WifiStore.subscribe_calls);
            try grt.std.testing.expectEqual(@as(usize, 0), WifiStore.live_subscriptions);
            try grt.std.testing.expectEqual(@as(usize, 1), WifiStore.unsubscribe_calls);
            try grt.std.testing.expectEqual(@as(usize, 1), CellularStore.subscribe_calls);
        }

        fn object_deinit_before_store_deinit_is_safe(allocator: glib.std.mem.Allocator) !void {
            const WifiStore = StoreObject.make(grt, struct {
                enabled: bool,
            }, .wifi);

            const S = makeTestStore(grt, struct {
                fn apply(builder: *DefaultBuilder) void {
                    builder.setStore(.wifi, WifiStore);
                    builder.setState("ui", .{.wifi});
                }
            }.apply);

            const wifi = WifiStore.init(allocator, .{
                .enabled = false,
            });
            var store = try S.init(allocator, .{
                .wifi = wifi,
            });

            try grt.std.testing.expectEqual(@as(usize, 1), store.stores.wifi.subscribers.items.len);

            store.stores.wifi.deinit();
            try grt.std.testing.expectEqual(@as(usize, 0), store.stores.wifi.subscribers.items.len);

            store.stores.wifi.set(.{ .enabled = true });
            store.stores.wifi.tick();
            try grt.std.testing.expect(!store.state.dirty.load(.acquire));
            try grt.std.testing.expect(!store.state.ui.dirty.load(.acquire));

            store.deinit();
        }

        fn handle_registers_and_removes_handlers_by_path(allocator: glib.std.mem.Allocator) !void {
            const Wifi = struct { value: u32 };
            const Cellular = struct { enabled: bool };

            const S = makeTestStore(grt, struct {
                fn apply(builder: *DefaultBuilder) void {
                    builder.setStore(.wifi, Wifi);
                    builder.setStore(.cellular, Cellular);
                    builder.setState("ui/home", .{});
                    builder.setState("device", .{});
                }
            }.apply);

            const Handlers = struct {
                pub fn onUiHome(_: *S.Stores) void {}
                pub fn onDevice(_: *S.Stores) void {}
            };

            var store = try S.init(allocator, .{
                .wifi = .{ .value = 1 },
                .cellular = .{ .enabled = false },
            });
            defer store.deinit();

            try grt.std.testing.expectEqual(@as(usize, 0), store.state.ui.home.handlers.items.len);
            try store.handle("ui/home", Handlers.onUiHome);
            try grt.std.testing.expectEqual(@as(usize, 1), store.state.ui.home.handlers.items.len);

            try store.handle("/ui/home/", Handlers.onUiHome);
            try grt.std.testing.expectEqual(@as(usize, 1), store.state.ui.home.handlers.items.len);

            try store.handle("device", Handlers.onDevice);
            try grt.std.testing.expectEqual(@as(usize, 1), store.state.device.handlers.items.len);

            try grt.std.testing.expect(store.unhandle("ui/home", Handlers.onUiHome));
            try grt.std.testing.expectEqual(@as(usize, 0), store.state.ui.home.handlers.items.len);
            try grt.std.testing.expect(!store.unhandle("ui/home", Handlers.onUiHome));
            try grt.std.testing.expect(store.unhandle("device", Handlers.onDevice));
            try grt.std.testing.expectEqual(@as(usize, 0), store.state.device.handlers.items.len);
        }

        fn handle_rejects_invalid_path(allocator: glib.std.mem.Allocator) !void {
            const Wifi = struct { value: u32 };

            const S = makeTestStore(grt, struct {
                fn apply(builder: *DefaultBuilder) void {
                    builder.setStore(.wifi, Wifi);
                    builder.setState("ui", .{});
                }
            }.apply);

            const Handlers = struct {
                pub fn onUi(_: *S.Stores) void {}
            };

            var store = try S.init(allocator, .{
                .wifi = .{ .value = 1 },
            });
            defer store.deinit();

            try grt.std.testing.expectError(error.InvalidPath, store.handle("ui/home", Handlers.onUi));
            try grt.std.testing.expectError(error.InvalidPath, store.handle("handlers", Handlers.onUi));
            try grt.std.testing.expect(!store.unhandle("ui/home", Handlers.onUi));
            try grt.std.testing.expect(!store.unhandle("dirty", Handlers.onUi));
        }

        fn make_binds_node_subscriber_to_storeobject(allocator: glib.std.mem.Allocator) !void {
            const WifiStore = StoreObject.make(grt, struct {
                enabled: bool,
            }, .wifi);

            const S = makeTestStore(grt, struct {
                fn apply(builder: *DefaultBuilder) void {
                    builder.setStore(.wifi, WifiStore);
                    builder.setState("ui", .{.wifi});
                }
            }.apply);

            const wifi = WifiStore.init(allocator, .{
                .enabled = false,
            });
            var store = try S.init(allocator, .{
                .wifi = wifi,
            });
            defer store.stores.wifi.deinit();
            defer store.deinit();

            try grt.std.testing.expect(!store.state.dirty.load(.acquire));
            try grt.std.testing.expect(!store.state.ui.dirty.load(.acquire));

            store.stores.wifi.set(.{ .enabled = true });
            store.stores.wifi.tick();

            try grt.std.testing.expect(store.state.dirty.load(.acquire));
            try grt.std.testing.expect(store.state.ui.dirty.load(.acquire));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.make_exposes_generated_Stores_type(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.make_exposes_generated_State_type(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.make_initializes_internal_state_and_node_subscriber(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.tick_runs_dirty_handlers_and_clears_flags(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.tick_runs_parent_handler_for_bound_storeobject(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.tick_runs_ancestor_handlers_without_clean_child_handlers(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.unhandle_prevents_future_tick_notifications(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.init_unbinds_partial_bindings_on_failure(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.object_deinit_before_store_deinit_is_safe(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.handle_registers_and_removes_handlers_by_path(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.handle_rejects_invalid_path(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.make_binds_node_subscriber_to_storeobject(allocator) catch |err| {
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
