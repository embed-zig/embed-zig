//! Timer coordination primitive — resettable deadline callback worker.
//!
//! `Timer.init(&impl)` erases a concrete timer implementation behind a small
//! vtable. `Timer.make(lib)` builds a default thread-backed implementation that
//! waits for an absolute millisecond deadline and invokes a callback once.

const stdz = @import("stdz");
const testing_api = @import("testing");

const Timer = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Callback = *const fn (ctx: *anyopaque) void;

pub const VTable = struct {
    reset: *const fn (ptr: *anyopaque, deadline_ms: ?u64) void,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub fn reset(self: Timer, deadline_ms: ?u64) void {
    self.vtable.reset(self.ptr, deadline_ms);
}

pub fn deinit(self: Timer) void {
    self.vtable.deinit(self.ptr);
}

pub fn init(pointer: anytype) Timer {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Timer.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const Gen = struct {
        fn resetFn(ptr: *anyopaque, deadline_ms: ?u64) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.reset(deadline_ms);
        }

        fn deinitFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        const vtable: VTable = .{
            .reset = resetFn,
            .deinit = deinitFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &Gen.vtable,
    };
}

pub fn make(comptime lib: type) type {
    return struct {
        pub const SpawnConfig = lib.Thread.SpawnConfig;

        allocator: stdz.mem.Allocator,
        callback: Timer.Callback,
        callback_ctx: *anyopaque,
        spawn_config: SpawnConfig,
        mutex: lib.Thread.Mutex = .{},
        cond: lib.Thread.Condition = .{},
        deadline_ms: ?u64 = null,
        shutting_down: bool = false,
        thread: ?lib.Thread = null,

        const Self = @This();

        pub fn init(
            allocator: stdz.mem.Allocator,
            callback: Timer.Callback,
            callback_ctx: *anyopaque,
            spawn_config: SpawnConfig,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .callback = callback,
                .callback_ctx = callback_ctx,
                .spawn_config = spawn_config,
            };

            self.thread = try lib.Thread.spawn(self.spawn_config, struct {
                fn run(timer: *Self) void {
                    timer.threadMain();
                }
            }.run, .{self});

            return self;
        }

        pub fn reset(self: *Self, deadline_ms: ?u64) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.deadline_ms = deadline_ms;
            self.cond.signal();
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            self.shutting_down = true;
            self.deadline_ms = null;
            self.cond.broadcast();
            self.mutex.unlock();

            if (self.thread) |thread| {
                thread.join();
                self.thread = null;
            }

            self.allocator.destroy(self);
        }

        fn threadMain(self: *Self) void {
            while (self.waitForFire()) {
                self.callback(self.callback_ctx);
            }
        }

        fn waitForFire(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (!self.shutting_down) {
                const deadline_ms = self.deadline_ms orelse {
                    self.cond.wait(&self.mutex);
                    continue;
                };

                const now_ms = currentMs();
                if (deadline_ms <= now_ms) {
                    self.deadline_ms = null;
                    return true;
                }

                self.cond.timedWait(&self.mutex, millisToWaitNs(deadline_ms - now_ms)) catch |err| switch (err) {
                    error.Timeout => {},
                };
            }

            return false;
        }

        fn currentMs() u64 {
            const now = lib.time.milliTimestamp();
            return if (now <= 0) 0 else @intCast(now);
        }

        fn millisToWaitNs(wait_ms: u64) u64 {
            if (wait_ms == 0) return 0;

            const max_wait_ms = lib.math.maxInt(u64) / lib.time.ns_per_ms;
            if (wait_ms >= max_wait_ms) return lib.math.maxInt(u64);
            return wait_ms * lib.time.ns_per_ms;
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            erasedWrapperCase(lib) catch |err| {
                t.logErrorf("sync.Timer erased wrapper failed: {}", .{err});
                return false;
            };
            resetNullCase(lib) catch |err| {
                t.logErrorf("sync.Timer reset(null) failed: {}", .{err});
                return false;
            };
            earlierResetCase(lib) catch |err| {
                t.logErrorf("sync.Timer earlier reset failed: {}", .{err});
                return false;
            };
            laterResetCase(lib) catch |err| {
                t.logErrorf("sync.Timer later reset failed: {}", .{err});
                return false;
            };
            rearmCase(lib) catch |err| {
                t.logErrorf("sync.Timer rearm failed: {}", .{err});
                return false;
            };
            immediateFireCase(lib) catch |err| {
                t.logErrorf("sync.Timer immediate fire failed: {}", .{err});
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

fn erasedWrapperCase(comptime lib: type) !void {
    const Mock = struct {
        deadline_ms: ?u64 = 99,
        deinit_called: bool = false,

        pub fn reset(self: *@This(), deadline_ms: ?u64) void {
            self.deadline_ms = deadline_ms;
        }

        pub fn deinit(self: *@This()) void {
            self.deinit_called = true;
        }
    };

    var mock = Mock{};
    const timer = Timer.init(&mock);
    timer.reset(123);
    try lib.testing.expectEqual(@as(?u64, 123), mock.deadline_ms);
    timer.reset(null);
    try lib.testing.expectEqual(@as(?u64, null), mock.deadline_ms);
    timer.deinit();
    try lib.testing.expect(mock.deinit_called);
}

fn resetNullCase(comptime lib: type) !void {
    const TimerImpl = make(lib);
    var callback_state = CallbackState(lib){};
    const timer = try TimerImpl.init(lib.testing.allocator, CallbackState(lib).fire, &callback_state, .{});
    defer timer.deinit();

    timer.reset(nowMs(lib) + 50);
    lib.Thread.sleep(10 * lib.time.ns_per_ms);
    timer.reset(null);

    try callback_state.expectStable(0, 100);
}

fn earlierResetCase(comptime lib: type) !void {
    const TimerImpl = make(lib);
    var callback_state = CallbackState(lib){};
    const timer = try TimerImpl.init(lib.testing.allocator, CallbackState(lib).fire, &callback_state, .{});
    defer timer.deinit();

    timer.reset(nowMs(lib) + 300);
    lib.Thread.sleep(20 * lib.time.ns_per_ms);
    timer.reset(nowMs(lib) + 100);

    _ = try callback_state.waitForCount(1, 500);
}

fn laterResetCase(comptime lib: type) !void {
    const TimerImpl = make(lib);
    var callback_state = CallbackState(lib){};
    const timer = try TimerImpl.init(lib.testing.allocator, CallbackState(lib).fire, &callback_state, .{});
    defer timer.deinit();

    timer.reset(nowMs(lib) + 100);
    lib.Thread.sleep(20 * lib.time.ns_per_ms);
    timer.reset(nowMs(lib) + 200);

    try callback_state.expectStable(0, 100);
    _ = try callback_state.waitForCount(1, 500);
}

fn rearmCase(comptime lib: type) !void {
    const TimerImpl = make(lib);
    var callback_state = CallbackState(lib){};
    const timer = try TimerImpl.init(lib.testing.allocator, CallbackState(lib).fire, &callback_state, .{});
    defer timer.deinit();

    timer.reset(nowMs(lib) + 100);
    _ = try callback_state.waitForCount(1, 500);

    timer.reset(nowMs(lib) + 100);
    _ = try callback_state.waitForCount(2, 500);
}

fn immediateFireCase(comptime lib: type) !void {
    const TimerImpl = make(lib);
    var callback_state = CallbackState(lib){};
    const timer = try TimerImpl.init(lib.testing.allocator, CallbackState(lib).fire, &callback_state, .{});
    defer timer.deinit();

    timer.reset(nowMs(lib));
    _ = try callback_state.waitForCount(1, 500);
}

fn nowMs(comptime lib: type) u64 {
    const now = lib.time.milliTimestamp();
    return if (now <= 0) 0 else @intCast(now);
}

fn CallbackState(comptime lib: type) type {
    return struct {
        mutex: lib.Thread.Mutex = .{},
        cond: lib.Thread.Condition = .{},
        fire_count: usize = 0,
        last_fire_ms: u64 = 0,

        const Self = @This();

        pub fn fire(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.mutex.lock();
            self.fire_count += 1;
            self.last_fire_ms = nowMs(lib);
            self.cond.broadcast();
            self.mutex.unlock();
        }

        fn waitForCount(self: *Self, expected: usize, timeout_ms: u64) !u64 {
            const start_ms = nowMs(lib);

            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.fire_count < expected) {
                const elapsed_ms = nowMs(lib) - start_ms;
                if (elapsed_ms >= timeout_ms) return error.TestTimeout;
                const remaining_ms = timeout_ms - elapsed_ms;
                self.cond.timedWait(&self.mutex, remaining_ms * lib.time.ns_per_ms) catch |err| switch (err) {
                    error.Timeout => return error.TestTimeout,
                };
            }

            return self.last_fire_ms;
        }

        fn expectStable(self: *Self, expected: usize, wait_ms: u64) !void {
            const start_ms = nowMs(lib);

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.fire_count != expected) return error.TestUnexpectedFireCount;

            while (true) {
                const elapsed_ms = nowMs(lib) - start_ms;
                if (elapsed_ms >= wait_ms) return;
                const remaining_ms = wait_ms - elapsed_ms;
                self.cond.timedWait(&self.mutex, remaining_ms * lib.time.ns_per_ms) catch |err| switch (err) {
                    error.Timeout => return,
                };
                if (self.fire_count != expected) return error.TestUnexpectedFireCount;
            }
        }
    };
}
