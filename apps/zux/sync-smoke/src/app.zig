const glib = @import("glib");
const glib_empty_zux_app = @import("glib_empty_zux_app");
const launcher = @import("launcher");

pub fn make(comptime platform_ctx: type, comptime platform_grt: type) type {
    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = glib_empty_zux_app.make(platform_grt);

        pub const title = "sync-smoke";
        pub const description = "Runtime sync primitive smoke test.";

        allocator: glib.std.mem.Allocator,
        zux_app: ZuxApp,

        pub fn init(allocator: glib.std.mem.Allocator, base_config: ZuxApp.InitConfig) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            var init_config = base_config;
            init_config.allocator = allocator;
            self.* = .{
                .allocator = allocator,
                .zux_app = try ZuxApp.init(init_config),
            };
            errdefer self.zux_app.deinit();

            try runSmoke(platform_ctx, platform_grt);
            return self;
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            self.zux_app.deinit();
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn start(self: *Self) !void {
            _ = self;
        }

        pub fn stop(self: *Self) void {
            _ = self;
        }

        pub fn createTestRunner() glib.testing.TestRunner {
            return testRunner(platform_ctx, platform_grt);
        }
    });
}

pub fn testRunner(comptime platform_ctx: type, comptime platform_grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: platform_grt.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: platform_grt.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            runSmoke(platform_ctx, platform_grt) catch |err| {
                t.logErrorf("sync smoke failed: {s}", .{@errorName(err)});
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: platform_grt.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

pub fn run(comptime platform_ctx: type, comptime platform_grt: type) !void {
    try platform_ctx.setup();
    defer platform_ctx.teardown();

    var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_sync_smoke);
    defer t.deinit();

    t.run("sync-smoke/primitives", testRunner(platform_ctx, platform_grt));
    if (!t.wait()) return error.TestFailed;
}

fn runSmoke(comptime platform_ctx: type, comptime platform_grt: type) !void {
    _ = platform_ctx;

    const log = platform_grt.std.log.scoped(.zux_sync_smoke);

    try smokeMutex(platform_grt);
    try smokeRwLock(platform_grt);
    try smokeCondition(platform_grt);

    log.info("sync smoke passed", .{});
}

fn smokeMutex(comptime platform_grt: type) !void {
    var mutex: platform_grt.sync.Mutex = .{};

    if (!mutex.tryLock()) return error.MutexTryLockFailed;
    mutex.unlock();

    mutex.lock();
    mutex.unlock();
}

fn smokeRwLock(comptime platform_grt: type) !void {
    var rwlock: platform_grt.sync.RwLock = .{};

    if (!rwlock.tryLockShared()) return error.RwLockSharedTryLockFailed;
    rwlock.unlockShared();

    if (!rwlock.tryLock()) return error.RwLockTryLockFailed;
    rwlock.unlock();

    rwlock.lockShared();
    rwlock.unlockShared();

    rwlock.lock();
    rwlock.unlock();
}

fn smokeCondition(comptime platform_grt: type) !void {
    const SyncState = struct {
        mutex: platform_grt.sync.Mutex = .{},
        ready: platform_grt.sync.Condition = .{},
        wake: platform_grt.sync.Condition = .{},
        ready_flag: bool = false,
        wake_flag: bool = false,
        woke: bool = false,
    };

    var timeout_mutex: platform_grt.sync.Mutex = .{};
    var timeout_condition: platform_grt.sync.Condition = .{};
    timeout_mutex.lock();
    try platform_grt.std.testing.expectError(error.Timeout, timeout_condition.timedWait(&timeout_mutex, 10 * glib.time.duration.MilliSecond));
    timeout_mutex.unlock();

    var state: SyncState = .{};
    const routine = glib.task.Routine.init(&state, conditionWaiter(SyncState).run);
    const handle = try platform_grt.task.go("zux/sync_smoke/wait", .{
        .min_stack_size = 4 * 1024,
    }, routine);

    state.mutex.lock();
    while (!state.ready_flag) {
        try state.ready.timedWait(&state.mutex, 1 * glib.time.duration.Second);
    }
    state.wake_flag = true;
    state.wake.signal();
    state.mutex.unlock();

    handle.join();

    if (!state.woke) return error.ConditionWaitFailed;
}

fn conditionWaiter(comptime SyncState: type) type {
    return struct {
        pub fn run(state: *SyncState) void {
            state.mutex.lock();
            state.ready_flag = true;
            state.ready.signal();
            while (!state.wake_flag) {
                state.wake.wait(&state.mutex);
            }
            state.woke = true;
            state.mutex.unlock();
        }
    };
}
