const StoreObject = @import("store/Object.zig");
const Subscriber = @import("store/Subscriber.zig");
const StoreState = @import("store/State.zig");
const StoreTypes = @import("store/Stores.zig");

pub fn make(comptime lib: type, comptime config: anytype) type {
    const Allocator = lib.mem.Allocator;

    return struct {
        const Self = @This();

        pub const Lib = lib;
        pub const Config = config;
        pub const Stores = StoreTypes.make(lib, config.stores);
        pub const State = StoreState.make(lib, config.state, HandlerFn);

        pub const HandleError = error{
            OutOfMemory,
            InvalidPath,
        };

        pub const HandlerFn = *const fn (stores: *Stores) void;

        allocator: Allocator,
        stores: Stores,
        state: *State,

        pub fn init(allocator: Allocator, stores: Stores) !Self {
            const state = try allocator.create(State);
            StoreState.init(lib, State, state);

            var self: Self = .{
                .allocator = allocator,
                .stores = stores,
                .state = state,
            };
            errdefer {
                StoreState.unbindStores(Stores, config.state, &self.stores, self.state);
                StoreState.deinit(lib, State, allocator, state);
                allocator.destroy(state);
            }

            try StoreState.bindStores(Stores, config.state, &self.stores, self.state);
            return self;
        }

        pub fn deinit(self: *Self) void {
            StoreState.unbindStores(Stores, config.state, &self.stores, self.state);
            StoreState.deinit(lib, State, self.allocator, self.state);
            self.allocator.destroy(self.state);
        }

        pub fn handle(self: *Self, comptime path: []const u8, handler: HandlerFn) HandleError!void {
            try StoreState.handlePath(path, self.allocator, self.state, handler);
        }

        pub fn unhandle(self: *Self, comptime path: []const u8, handler: HandlerFn) bool {
            return StoreState.unhandlePath(path, self.state, handler);
        }

        pub fn tick(self: *Self) void {
            StoreState.tick(State, self.state, &self.stores);
        }
    };
}

test "zux/unit_tests/Store/make_exposes_generated_Stores_type" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
        pub const atomic = struct {
            pub fn Value(comptime U: type) type {
                return std.atomic.Value(U);
            }
        };
        pub const mem = struct {
            pub const Allocator = std.mem.Allocator;
        };
        pub fn ArrayList(comptime Elem: type) type {
            return std.ArrayList(Elem);
        }
    };

    const Wifi = struct { value: u32 };
    const Cellular = struct { enabled: bool };

    const S = make(TestLib, .{
        .stores = .{
            .wifi = Wifi,
            .cellular = Cellular,
        },
        .state = .{},
    });

    const stores: S.Stores = .{
        .wifi = .{ .value = 1 },
        .cellular = .{ .enabled = false },
    };

    var store = try S.init(std.testing.allocator, stores);
    defer store.deinit();
    try std.testing.expectEqual(@as(u32, 1), store.stores.wifi.value);
    try std.testing.expect(!store.stores.cellular.enabled);
}

test "zux/unit_tests/Store/make_exposes_generated_State_type" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
        pub const atomic = struct {
            pub fn Value(comptime U: type) type {
                return std.atomic.Value(U);
            }
        };
        pub const mem = struct {
            pub const Allocator = std.mem.Allocator;
        };
        pub fn ArrayList(comptime Elem: type) type {
            return std.ArrayList(Elem);
        }
    };

    const Wifi = struct { value: u32 };
    const Cellular = struct { enabled: bool };

    const S = make(TestLib, .{
        .stores = .{
            .wifi = Wifi,
            .cellular = Cellular,
        },
        .state = .{
            .ui = .{
                .stores = &.{ .wifi, .cellular },
                .home = .{
                    .stores = &.{.wifi},
                },
            },
        },
    });

    try std.testing.expect(@hasField(S.State, "dirty"));
    try std.testing.expect(@hasField(S.State, "handlers"));
    try std.testing.expect(@hasField(S.State, "ui"));
    try std.testing.expect(@hasField(@FieldType(S.State, "ui"), "home"));
}

test "zux/unit_tests/Store/make_initializes_internal_state_and_node_subscriber" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
        pub const atomic = struct {
            pub fn Value(comptime U: type) type {
                return std.atomic.Value(U);
            }
        };
        pub const mem = struct {
            pub const Allocator = std.mem.Allocator;
        };
        pub fn ArrayList(comptime Elem: type) type {
            return std.ArrayList(Elem);
        }
    };

    const Wifi = struct { value: u32 };

    const S = make(TestLib, .{
        .stores = .{
            .wifi = Wifi,
        },
        .state = .{
            .ui = .{},
        },
    });

    const stores: S.Stores = .{
        .wifi = .{ .value = 9 },
    };

    var store = try S.init(std.testing.allocator, stores);
    defer store.deinit();

    try std.testing.expect(!store.state.dirty.load(.acquire));
    try std.testing.expect(!store.state.ui.dirty.load(.acquire));

    store.state.ui.subscriber.notify(.{
        .label = "wifi",
        .tick_count = 1,
    });

    try std.testing.expect(store.state.dirty.load(.acquire));
    try std.testing.expect(store.state.ui.dirty.load(.acquire));
}

test "zux/unit_tests/Store/tick_runs_dirty_handlers_and_clears_flags" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
        pub const atomic = struct {
            pub fn Value(comptime U: type) type {
                return std.atomic.Value(U);
            }
        };
        pub const mem = struct {
            pub const Allocator = std.mem.Allocator;
        };
        pub fn ArrayList(comptime Elem: type) type {
            return std.ArrayList(Elem);
        }
    };

    const Wifi = struct { value: u32 };

    const S = make(TestLib, .{
        .stores = .{
            .wifi = Wifi,
        },
        .state = .{
            .ui = .{
                .home = .{},
            },
        },
    });

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

    var store = try S.init(std.testing.allocator, .{
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

    try std.testing.expect(store.state.dirty.load(.acquire));
    try std.testing.expect(store.state.ui.dirty.load(.acquire));
    try std.testing.expect(store.state.ui.home.dirty.load(.acquire));

    store.tick();

    try std.testing.expectEqual(@as(usize, 1), Recorder.root_calls);
    try std.testing.expectEqual(@as(usize, 1), Recorder.ui_calls);
    try std.testing.expectEqual(@as(usize, 1), Recorder.home_calls);
    try std.testing.expect(!store.state.dirty.load(.acquire));
    try std.testing.expect(!store.state.ui.dirty.load(.acquire));
    try std.testing.expect(!store.state.ui.home.dirty.load(.acquire));

    store.tick();

    try std.testing.expectEqual(@as(usize, 1), Recorder.root_calls);
    try std.testing.expectEqual(@as(usize, 1), Recorder.ui_calls);
    try std.testing.expectEqual(@as(usize, 1), Recorder.home_calls);
}

test "zux/unit_tests/Store/tick_runs_parent_handler_for_bound_storeobject" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
        pub const atomic = struct {
            pub fn Value(comptime U: type) type {
                return std.atomic.Value(U);
            }
        };
        pub const mem = struct {
            pub const Allocator = std.mem.Allocator;
        };
        pub const Thread = struct {
            pub const Mutex = struct {
                pub fn lock(_: *@This()) void {}
                pub fn unlock(_: *@This()) void {}
            };
            pub const RwLock = struct {
                pub fn lockShared(_: *@This()) void {}
                pub fn unlockShared(_: *@This()) void {}
                pub fn lock(_: *@This()) void {}
                pub fn unlock(_: *@This()) void {}
                pub fn tryLockShared(_: *@This()) bool { return true; }
                pub fn tryLock(_: *@This()) bool { return true; }
            };
        };
        pub fn ArrayList(comptime Elem: type) type {
            return std.ArrayList(Elem);
        }
    };

    const WifiStore = StoreObject.make(TestLib, struct {
        enabled: bool,
    }, .wifi);

    const S = make(TestLib, .{
        .stores = .{
            .wifi = WifiStore,
        },
        .state = .{
            .ui = .{
                .stores = &.{.wifi},
            },
        },
    });

    const Recorder = struct {
        var calls: usize = 0;

        pub fn onUi(_: *S.Stores) void {
            calls += 1;
        }
    };

    Recorder.calls = 0;

    const wifi = WifiStore.init(std.testing.allocator, .{
        .enabled = false,
    });
    var store = try S.init(std.testing.allocator, .{
        .wifi = wifi,
    });
    defer store.stores.wifi.deinit();
    defer store.deinit();

    try store.handle("ui", Recorder.onUi);

    store.stores.wifi.set(.{ .enabled = true });
    store.stores.wifi.tick();
    store.tick();

    try std.testing.expectEqual(@as(usize, 1), Recorder.calls);
    try std.testing.expect(!store.state.dirty.load(.acquire));
    try std.testing.expect(!store.state.ui.dirty.load(.acquire));
}

test "zux/unit_tests/Store/tick_runs_ancestor_handlers_without_clean_child_handlers" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
        pub const atomic = struct {
            pub fn Value(comptime U: type) type {
                return std.atomic.Value(U);
            }
        };
        pub const mem = struct {
            pub const Allocator = std.mem.Allocator;
        };
        pub fn ArrayList(comptime Elem: type) type {
            return std.ArrayList(Elem);
        }
    };

    const Wifi = struct { value: u32 };

    const S = make(TestLib, .{
        .stores = .{
            .wifi = Wifi,
        },
        .state = .{
            .ui = .{
                .home = .{},
            },
        },
    });

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

    var store = try S.init(std.testing.allocator, .{
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

    try std.testing.expect(store.state.dirty.load(.acquire));
    try std.testing.expect(store.state.ui.dirty.load(.acquire));
    try std.testing.expect(!store.state.ui.home.dirty.load(.acquire));

    store.tick();

    try std.testing.expectEqual(@as(usize, 1), Recorder.root_calls);
    try std.testing.expectEqual(@as(usize, 1), Recorder.ui_calls);
    try std.testing.expectEqual(@as(usize, 0), Recorder.home_calls);
    try std.testing.expect(!store.state.dirty.load(.acquire));
    try std.testing.expect(!store.state.ui.dirty.load(.acquire));
    try std.testing.expect(!store.state.ui.home.dirty.load(.acquire));
}

test "zux/unit_tests/Store/unhandle_prevents_future_tick_notifications" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
        pub const atomic = struct {
            pub fn Value(comptime U: type) type {
                return std.atomic.Value(U);
            }
        };
        pub const mem = struct {
            pub const Allocator = std.mem.Allocator;
        };
        pub fn ArrayList(comptime Elem: type) type {
            return std.ArrayList(Elem);
        }
    };

    const Wifi = struct { value: u32 };

    const S = make(TestLib, .{
        .stores = .{
            .wifi = Wifi,
        },
        .state = .{
            .ui = .{
                .home = .{},
            },
        },
    });

    const Recorder = struct {
        var calls: usize = 0;

        pub fn onHome(_: *S.Stores) void {
            calls += 1;
        }
    };

    Recorder.calls = 0;

    var store = try S.init(std.testing.allocator, .{
        .wifi = .{ .value = 1 },
    });
    defer store.deinit();

    try store.handle("ui/home", Recorder.onHome);

    store.state.ui.home.subscriber.notify(.{
        .label = "wifi",
        .tick_count = 1,
    });
    store.tick();

    try std.testing.expectEqual(@as(usize, 1), Recorder.calls);
    try std.testing.expect(store.unhandle("ui/home", Recorder.onHome));

    store.state.ui.home.subscriber.notify(.{
        .label = "wifi",
        .tick_count = 2,
    });
    store.tick();

    try std.testing.expectEqual(@as(usize, 1), Recorder.calls);
}

test "zux/unit_tests/Store/init_unbinds_partial_bindings_on_failure" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
        pub const atomic = struct {
            pub fn Value(comptime U: type) type {
                return std.atomic.Value(U);
            }
        };
        pub const mem = struct {
            pub const Allocator = std.mem.Allocator;
        };
        pub fn ArrayList(comptime Elem: type) type {
            return std.ArrayList(Elem);
        }
    };

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

    const S = make(TestLib, .{
        .stores = .{
            .wifi = WifiStore,
            .cellular = CellularStore,
        },
        .state = .{
            .ui = .{
                .stores = &.{ .wifi, .cellular },
            },
        },
    });

    WifiStore.subscribe_calls = 0;
    WifiStore.unsubscribe_calls = 0;
    WifiStore.live_subscriptions = 0;
    CellularStore.subscribe_calls = 0;
    CellularStore.unsubscribe_calls = 0;

    const stores: S.Stores = .{
        .wifi = .{},
        .cellular = .{},
    };

    try std.testing.expectError(error.OutOfMemory, S.init(std.testing.allocator, stores));
    try std.testing.expectEqual(@as(usize, 1), WifiStore.subscribe_calls);
    try std.testing.expectEqual(@as(usize, 0), WifiStore.live_subscriptions);
    try std.testing.expectEqual(@as(usize, 1), WifiStore.unsubscribe_calls);
    try std.testing.expectEqual(@as(usize, 1), CellularStore.subscribe_calls);
}

test "zux/unit_tests/Store/object_deinit_before_store_deinit_is_safe" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
        pub const atomic = struct {
            pub fn Value(comptime U: type) type {
                return std.atomic.Value(U);
            }
        };
        pub const mem = struct {
            pub const Allocator = std.mem.Allocator;
        };
        pub const Thread = struct {
            pub const Mutex = struct {
                pub fn lock(_: *@This()) void {}
                pub fn unlock(_: *@This()) void {}
            };
            pub const RwLock = struct {
                pub fn lockShared(_: *@This()) void {}
                pub fn unlockShared(_: *@This()) void {}
                pub fn lock(_: *@This()) void {}
                pub fn unlock(_: *@This()) void {}
                pub fn tryLockShared(_: *@This()) bool { return true; }
                pub fn tryLock(_: *@This()) bool { return true; }
            };
        };
        pub fn ArrayList(comptime Elem: type) type {
            return std.ArrayList(Elem);
        }
    };

    const WifiStore = StoreObject.make(TestLib, struct {
        enabled: bool,
    }, .wifi);

    const S = make(TestLib, .{
        .stores = .{
            .wifi = WifiStore,
        },
        .state = .{
            .ui = .{
                .stores = &.{.wifi},
            },
        },
    });

    const wifi = WifiStore.init(std.testing.allocator, .{
        .enabled = false,
    });
    var store = try S.init(std.testing.allocator, .{
        .wifi = wifi,
    });

    try std.testing.expectEqual(@as(usize, 1), store.stores.wifi.subscribers.items.len);

    store.stores.wifi.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.stores.wifi.subscribers.items.len);

    store.stores.wifi.set(.{ .enabled = true });
    store.stores.wifi.tick();
    try std.testing.expect(!store.state.dirty.load(.acquire));
    try std.testing.expect(!store.state.ui.dirty.load(.acquire));

    store.deinit();
}

test "zux/unit_tests/Store/handle_registers_and_removes_handlers_by_path" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
        pub const atomic = struct {
            pub fn Value(comptime U: type) type {
                return std.atomic.Value(U);
            }
        };
        pub const mem = struct {
            pub const Allocator = std.mem.Allocator;
        };
        pub fn ArrayList(comptime Elem: type) type {
            return std.ArrayList(Elem);
        }
    };

    const Wifi = struct { value: u32 };
    const Cellular = struct { enabled: bool };

    const S = make(TestLib, .{
        .stores = .{
            .wifi = Wifi,
            .cellular = Cellular,
        },
        .state = .{
            .ui = .{
                .home = .{},
            },
            .device = .{},
        },
    });

    const Handlers = struct {
        pub fn onUiHome(_: *S.Stores) void {}
        pub fn onDevice(_: *S.Stores) void {}
    };

    var store = try S.init(std.testing.allocator, .{
        .wifi = .{ .value = 1 },
        .cellular = .{ .enabled = false },
    });
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.state.ui.home.handlers.items.len);
    try store.handle("ui/home", Handlers.onUiHome);
    try std.testing.expectEqual(@as(usize, 1), store.state.ui.home.handlers.items.len);

    try store.handle("/ui/home/", Handlers.onUiHome);
    try std.testing.expectEqual(@as(usize, 1), store.state.ui.home.handlers.items.len);

    try store.handle("device", Handlers.onDevice);
    try std.testing.expectEqual(@as(usize, 1), store.state.device.handlers.items.len);

    try std.testing.expect(store.unhandle("ui/home", Handlers.onUiHome));
    try std.testing.expectEqual(@as(usize, 0), store.state.ui.home.handlers.items.len);
    try std.testing.expect(!store.unhandle("ui/home", Handlers.onUiHome));
    try std.testing.expect(store.unhandle("device", Handlers.onDevice));
    try std.testing.expectEqual(@as(usize, 0), store.state.device.handlers.items.len);
}

test "zux/unit_tests/Store/handle_rejects_invalid_path" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
        pub const atomic = struct {
            pub fn Value(comptime U: type) type {
                return std.atomic.Value(U);
            }
        };
        pub const mem = struct {
            pub const Allocator = std.mem.Allocator;
        };
        pub fn ArrayList(comptime Elem: type) type {
            return std.ArrayList(Elem);
        }
    };

    const Wifi = struct { value: u32 };

    const S = make(TestLib, .{
        .stores = .{
            .wifi = Wifi,
        },
        .state = .{
            .ui = .{},
        },
    });

    const Handlers = struct {
        pub fn onUi(_: *S.Stores) void {}
    };

    var store = try S.init(std.testing.allocator, .{
        .wifi = .{ .value = 1 },
    });
    defer store.deinit();

    try std.testing.expectError(error.InvalidPath, store.handle("ui/home", Handlers.onUi));
    try std.testing.expectError(error.InvalidPath, store.handle("handlers", Handlers.onUi));
    try std.testing.expect(!store.unhandle("ui/home", Handlers.onUi));
    try std.testing.expect(!store.unhandle("dirty", Handlers.onUi));
}

test "zux/unit_tests/Store/make_binds_node_subscriber_to_storeobject" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
        pub const atomic = struct {
            pub fn Value(comptime U: type) type {
                return std.atomic.Value(U);
            }
        };
        pub const mem = struct {
            pub const Allocator = std.mem.Allocator;
        };
        pub const Thread = struct {
            pub const Mutex = struct {
                pub fn lock(_: *@This()) void {}
                pub fn unlock(_: *@This()) void {}
            };
            pub const RwLock = struct {
                pub fn lockShared(_: *@This()) void {}
                pub fn unlockShared(_: *@This()) void {}
                pub fn lock(_: *@This()) void {}
                pub fn unlock(_: *@This()) void {}
                pub fn tryLockShared(_: *@This()) bool { return true; }
                pub fn tryLock(_: *@This()) bool { return true; }
            };
        };
        pub fn ArrayList(comptime Elem: type) type {
            return std.ArrayList(Elem);
        }
    };

    const WifiStore = StoreObject.make(TestLib, struct {
        enabled: bool,
    }, .wifi);

    const S = make(TestLib, .{
        .stores = .{
            .wifi = WifiStore,
        },
        .state = .{
            .ui = .{
                .stores = &.{.wifi},
            },
        },
    });

    const wifi = WifiStore.init(std.testing.allocator, .{
        .enabled = false,
    });
    var store = try S.init(std.testing.allocator, .{
        .wifi = wifi,
    });
    defer store.stores.wifi.deinit();
    defer store.deinit();

    try std.testing.expect(!store.state.dirty.load(.acquire));
    try std.testing.expect(!store.state.ui.dirty.load(.acquire));

    store.stores.wifi.set(.{ .enabled = true });
    store.stores.wifi.tick();

    try std.testing.expect(store.state.dirty.load(.acquire));
    try std.testing.expect(store.state.ui.dirty.load(.acquire));
}
