const testing_api = @import("testing");

const Assembler = @import("../../../../Assembler.zig");
const ui_route = @import("../../../../component/ui/route.zig");

fn makeBuiltApp(comptime lib: type, comptime Channel: fn (type) type) type {
    const AssemblerType = Assembler.make(lib, .{}, Channel);
    var assembler = AssemblerType.init();
    assembler.addRouter(.route, 51, .{
        .screen_id = 1,
    });
    assembler.setState("ui/route", .{.route});

    const BuildConfig = assembler.BuildConfig();
    const build_config: BuildConfig = .{};
    return assembler.build(build_config);
}

fn TestCase(comptime lib: type, comptime BuiltApp: type) type {
    return struct {
        const Self = @This();
        const Failure = enum {
            missing_callback_count,
            unexpected_callback_count,
            wrong_version,
            wrong_current_page,
            wrong_state_transitioning,
            wrong_depth,
            wrong_transitioning,
            wrong_item,
            timed_out_waiting_for_route,
        };

        var callback_mu: lib.Thread.Mutex = .{};
        var callback_calls: usize = 0;
        var callback_failure: ?Failure = null;
        const expected_callback_count = 7;

        pub fn init(self: *Self, allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
            reset();
        }

        pub fn run(self: *Self, t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            var app = BuiltApp.init(.{
                .allocator = allocator,
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer app.deinit();

            app.store.handle("ui/route", Self.onRoute) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer _ = app.store.unhandle("ui/route", Self.onRoute);

            const initial_state = app.store.stores.route.get();
            const initial_router = app.router(.route);
            if (initial_state.current_page != 1 or initial_state.transitioning != false or initial_state.version != 0) {
                t.logFatal("invalid initial route state");
                return false;
            }
            if (initial_router.currentPage() != 1 or initial_router.depth() != 1 or initial_router.version() != 0) {
                t.logFatal("invalid initial router snapshot");
                return false;
            }

            app.start() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            driveSequence(&app) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            app.stop() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            if (currentFailure()) |failure| {
                t.logFatal(@tagName(failure));
                return false;
            }
            if (currentCallbackCalls() != expected_callback_count) {
                t.logFatal(@tagName(Failure.missing_callback_count));
                return false;
            }

            const final_router = app.router(.route);
            const final_state = app.store.stores.route.get();
            if (final_state.current_page != 1 or final_state.transitioning != false or final_state.version != expected_callback_count) {
                t.logFatal("invalid final route state");
                return false;
            }
            if (final_router.currentPage() != 1 or final_router.depth() != 1 or final_router.version() != expected_callback_count) {
                t.logFatal("invalid final router snapshot");
                return false;
            }
            return true;
        }

        pub fn deinit(self: *Self, allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        pub fn onRoute(stores: *BuiltApp.Store.Stores) void {
            callback_mu.lock();
            defer callback_mu.unlock();

            callback_calls += 1;
            const state = stores.route.get();
            const router = stores.route.router();
            switch (callback_calls) {
                1 => {
                    const expected = [_]ui_route.Router.Item{
                        .{ .screen_id = 1 },
                        .{ .screen_id = 2, .arg0 = 7 },
                    };
                    checkSnapshotLocked(state, router, 1, 2, false, expected[0..]);
                },
                2 => {
                    const expected = [_]ui_route.Router.Item{
                        .{ .screen_id = 1 },
                        .{ .screen_id = 3, .arg1 = 9 },
                    };
                    checkSnapshotLocked(state, router, 2, 3, false, expected[0..]);
                },
                3 => {
                    const expected = [_]ui_route.Router.Item{
                        .{ .screen_id = 1 },
                        .{ .screen_id = 3, .arg1 = 9 },
                    };
                    checkSnapshotLocked(state, router, 3, 3, true, expected[0..]);
                },
                4 => {
                    const expected = [_]ui_route.Router.Item{
                        .{ .screen_id = 1 },
                        .{ .screen_id = 3, .arg1 = 9 },
                        .{ .screen_id = 4, .flags = 1 },
                    };
                    checkSnapshotLocked(state, router, 4, 4, true, expected[0..]);
                },
                5 => {
                    const expected = [_]ui_route.Router.Item{
                        .{ .screen_id = 1 },
                        .{ .screen_id = 3, .arg1 = 9 },
                    };
                    checkSnapshotLocked(state, router, 5, 3, true, expected[0..]);
                },
                6 => {
                    const expected = [_]ui_route.Router.Item{
                        .{ .screen_id = 1 },
                    };
                    checkSnapshotLocked(state, router, 6, 1, true, expected[0..]);
                },
                7 => {
                    const expected = [_]ui_route.Router.Item{
                        .{ .screen_id = 1 },
                    };
                    checkSnapshotLocked(state, router, 7, 1, false, expected[0..]);
                },
                else => failLocked(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            try app.push_route(.route, .{
                .screen_id = 2,
                .arg0 = 7,
            });
            try waitForCallbackCount(1);

            try app.replace_route(.route, .{
                .screen_id = 3,
                .arg1 = 9,
            });
            try waitForCallbackCount(2);

            try app.set_route_transitioning(.route, true);
            try waitForCallbackCount(3);

            try app.push_route(.route, .{
                .screen_id = 4,
                .flags = 1,
            });
            try waitForCallbackCount(4);

            try app.pop_route(.route);
            try waitForCallbackCount(5);

            try app.pop_route_to_root(.route);
            try waitForCallbackCount(6);

            try app.set_route_transitioning(.route, false);
            try waitForCallbackCount(7);
        }

        fn checkSnapshotLocked(
            state: anytype,
            router: ui_route.Router,
            expected_version: u64,
            expected_current_page: u32,
            expected_transitioning: bool,
            expected_items: []const ui_route.Router.Item,
        ) void {
            if (state.version != expected_version or router.version() != expected_version) {
                failLocked(.wrong_version);
                return;
            }
            if (state.current_page != expected_current_page or router.currentPage() != expected_current_page) {
                failLocked(.wrong_current_page);
                return;
            }
            if (state.transitioning != expected_transitioning) {
                failLocked(.wrong_state_transitioning);
                return;
            }
            if (router.depth() != expected_items.len) {
                failLocked(.wrong_depth);
                return;
            }
            if (router.transitioning() != expected_transitioning) {
                failLocked(.wrong_transitioning);
                return;
            }
            for (expected_items, 0..) |expected, i| {
                const actual = router.item(i) orelse {
                    failLocked(.wrong_item);
                    return;
                };
                if (!itemEql(actual, expected)) {
                    failLocked(.wrong_item);
                    return;
                }
            }
        }

        fn itemEql(a: ui_route.Router.Item, b: ui_route.Router.Item) bool {
            return a.screen_id == b.screen_id and
                a.arg0 == b.arg0 and
                a.arg1 == b.arg1 and
                a.flags == b.flags;
        }

        fn reset() void {
            callback_mu.lock();
            defer callback_mu.unlock();
            callback_calls = 0;
            callback_failure = null;
        }

        fn failLocked(next: Failure) void {
            if (callback_failure == null) {
                callback_failure = next;
            }
        }

        fn currentCallbackCalls() usize {
            callback_mu.lock();
            defer callback_mu.unlock();
            return callback_calls;
        }

        fn currentFailure() ?Failure {
            callback_mu.lock();
            defer callback_mu.unlock();
            return callback_failure;
        }

        fn waitForCallbackCount(expected: usize) !void {
            var attempts: usize = 0;
            while (attempts < 300) : (attempts += 1) {
                if (currentCallbackCalls() >= expected) return;
                lib.Thread.sleep(10 * lib.time.ns_per_ms);
            }
            callback_mu.lock();
            defer callback_mu.unlock();
            failLocked(.timed_out_waiting_for_route);
            return error.TimedOut;
        }
    };
}

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const BuiltApp = comptime makeBuiltApp(lib, Channel);
    const Case = TestCase(lib, BuiltApp);

    const Holder = struct {
        var runner: Case = .{};
    };
    return testing_api.TestRunner.make(Case).new(&Holder.runner);
}
