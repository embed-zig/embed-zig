//! Timer coordination primitive — resettable deadline callback worker.
//!
//! `Timer.init(&impl)` erases a concrete timer implementation behind a small
//! vtable. `Timer.make(std, time)` builds a default task-backed implementation
//! that waits for an absolute monotonic deadline and invokes a callback once.

const stdz = @import("stdz");
const task_mod = @import("task");
const time_mod = @import("time");
const testing_api = @import("testing");

const Timer = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Callback = *const fn (ctx: *anyopaque) void;

pub const VTable = struct {
    reset: *const fn (ptr: *anyopaque, deadline: ?time_mod.instant.Time) void,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub fn reset(self: Timer, deadline: ?time_mod.instant.Time) void {
    self.vtable.reset(self.ptr, deadline);
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
        fn resetFn(ptr: *anyopaque, deadline: ?time_mod.instant.Time) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.reset(deadline);
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

pub fn make(comptime std: type, comptime time: type) type {
    if (!@hasDecl(std, "sync")) {
        @compileError("Timer.make requires std.sync; pass glib.make/gstd runtime or use Timer.makeWithTask");
    }
    if (!@hasDecl(std, "task")) {
        @compileError("Timer.make requires std.task; pass glib.make/gstd runtime or use Timer.makeWithTask");
    }
    return makeWithTask(std, time, std.sync, std.task);
}

pub fn makeWithSync(comptime std: type, comptime time: type, comptime sync: type) type {
    _ = std;
    _ = time;
    _ = sync;
    @compileError("Timer.makeWithSync is removed; use Timer.makeWithTask");
}

pub fn makeWithTask(comptime std: type, comptime time: type, comptime sync: type, comptime task: type) type {
    _ = std;
    return struct {
        pub const Options = task.Options;

        allocator: stdz.mem.Allocator,
        callback: Timer.Callback,
        callback_ctx: *anyopaque,
        task_options: Options,
        mutex: sync.Mutex = .{},
        cond: sync.Condition = .{},
        deadline: ?time.instant.Time = null,
        shutting_down: bool = false,
        worker: ?task.Handle = null,

        const Self = @This();

        pub fn init(
            allocator: stdz.mem.Allocator,
            callback: Timer.Callback,
            callback_ctx: *anyopaque,
            task_options: Options,
        ) (stdz.mem.Allocator.Error || task.SpawnError)!*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .callback = callback,
                .callback_ctx = callback_ctx,
                .task_options = task_options,
            };

            self.worker = try task.go("sync/timer", self.task_options, task.Routine.init(self, runTask));

            return self;
        }

        pub fn reset(self: *Self, deadline: ?time.instant.Time) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.deadline = deadline;
            self.cond.signal();
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            self.shutting_down = true;
            self.deadline = null;
            self.cond.broadcast();
            self.mutex.unlock();

            if (self.worker) |worker| {
                worker.join();
                self.worker = null;
            }

            self.allocator.destroy(self);
        }

        fn runTask(self: *Self) void {
            while (self.waitForFire()) {
                self.callback(self.callback_ctx);
            }
        }

        fn waitForFire(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (!self.shutting_down) {
                const deadline = self.deadline orelse {
                    self.cond.wait(&self.mutex);
                    continue;
                };

                const remaining = time.instant.sub(deadline, time.instant.now());
                if (remaining <= 0) {
                    self.deadline = null;
                    return true;
                }

                self.cond.timedWait(&self.mutex, @intCast(remaining)) catch |err| switch (err) {
                    error.Timeout => {},
                };
            }

            return false;
        }
    };
}

pub fn TestRunner(comptime std: type, comptime time: type) testing_api.TestRunner {
    const native_std = @import("std");
    const sync = struct {
        const NativeWorker = @field(native_std, "Thread");

        pub const Mutex = @import("Mutex.zig").make(NativeWorker.Mutex);
        pub const Condition = @import("Condition.zig").make(NativeWorker.Condition);
    };
    const task = struct {
        const NativeWorker = @field(native_std, "Thread");

        pub const Handle = NativeWorker;
        pub const Options = task_mod.Options;
        pub const Routine = task_mod.Routine;
        pub const SpawnError = NativeWorker.SpawnError;

        pub fn go(_: []const u8, options: Options, routine: Routine) SpawnError!Handle {
            return NativeWorker.spawn(.{
                .stack_size = stackSize(options.min_stack_size),
            }, runRoutine, .{routine});
        }

        pub fn currentToken() usize {
            const value: usize = @intCast(NativeWorker.getCurrentId());
            return if (value == 0) 1 else value;
        }

        fn runRoutine(routine: Routine) void {
            routine.run();
        }

        fn stackSize(min_stack_size: usize) usize {
            if (min_stack_size == 0) return NativeWorker.SpawnConfig.default_stack_size;
            return min_stack_size;
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            erasedWrapperCase(std) catch |err| {
                t.logErrorf("sync.Timer erased wrapper failed: {}", .{err});
                return false;
            };
            resetNullCase(std, time, sync, task) catch |err| {
                t.logErrorf("sync.Timer reset(null) failed: {}", .{err});
                return false;
            };
            earlierResetCase(std, time, sync, task) catch |err| {
                t.logErrorf("sync.Timer earlier reset failed: {}", .{err});
                return false;
            };
            laterResetCase(std, time, sync, task) catch |err| {
                t.logErrorf("sync.Timer later reset failed: {}", .{err});
                return false;
            };
            rearmCase(std, time, sync, task) catch |err| {
                t.logErrorf("sync.Timer rearm failed: {}", .{err});
                return false;
            };
            immediateFireCase(std, time, sync, task) catch |err| {
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

fn erasedWrapperCase(comptime std: type) !void {
    const Mock = struct {
        deadline: ?time_mod.instant.Time = 99,
        deinit_called: bool = false,

        pub fn reset(self: *@This(), deadline: ?time_mod.instant.Time) void {
            self.deadline = deadline;
        }

        pub fn deinit(self: *@This()) void {
            self.deinit_called = true;
        }
    };

    var mock = Mock{};
    const timer = Timer.init(&mock);
    timer.reset(123);
    try std.testing.expectEqual(@as(?time_mod.instant.Time, 123), mock.deadline);
    timer.reset(null);
    try std.testing.expectEqual(@as(?time_mod.instant.Time, null), mock.deadline);
    timer.deinit();
    try std.testing.expect(mock.deinit_called);
}

fn resetNullCase(comptime std: type, comptime time: type, comptime sync: type, comptime task: type) !void {
    const TimerImpl = makeWithTask(std, time, sync, task);
    var callback_state = CallbackState(time, sync){};
    const timer = try TimerImpl.init(std.testing.allocator, CallbackState(time, sync).fire, &callback_state, .{});
    defer timer.deinit();

    timer.reset(time.instant.add(time.instant.now(), 500 * time.duration.MilliSecond));
    time.sleep(50 * time.duration.MilliSecond);
    timer.reset(null);

    try callback_state.expectStable(0, 200 * time.duration.MilliSecond);
}

fn earlierResetCase(comptime std: type, comptime time: type, comptime sync: type, comptime task: type) !void {
    const TimerImpl = makeWithTask(std, time, sync, task);
    var callback_state = CallbackState(time, sync){};
    const timer = try TimerImpl.init(std.testing.allocator, CallbackState(time, sync).fire, &callback_state, .{});
    defer timer.deinit();

    timer.reset(time.instant.add(time.instant.now(), 120 * time.duration.MilliSecond));
    time.sleep(10 * time.duration.MilliSecond);
    timer.reset(time.instant.add(time.instant.now(), 20 * time.duration.MilliSecond));

    _ = try callback_state.waitForCount(1, 100 * time.duration.MilliSecond);
}

fn laterResetCase(comptime std: type, comptime time: type, comptime sync: type, comptime task: type) !void {
    const TimerImpl = makeWithTask(std, time, sync, task);
    var callback_state = CallbackState(time, sync){};
    const timer = try TimerImpl.init(std.testing.allocator, CallbackState(time, sync).fire, &callback_state, .{});
    defer timer.deinit();

    timer.reset(time.instant.add(time.instant.now(), 500 * time.duration.MilliSecond));
    time.sleep(50 * time.duration.MilliSecond);
    timer.reset(time.instant.add(time.instant.now(), 200 * time.duration.MilliSecond));

    try callback_state.expectStable(0, 100 * time.duration.MilliSecond);
    _ = try callback_state.waitForCount(1, 250 * time.duration.MilliSecond);
}

fn rearmCase(comptime std: type, comptime time: type, comptime sync: type, comptime task: type) !void {
    const TimerImpl = makeWithTask(std, time, sync, task);
    var callback_state = CallbackState(time, sync){};
    const timer = try TimerImpl.init(std.testing.allocator, CallbackState(time, sync).fire, &callback_state, .{});
    defer timer.deinit();

    timer.reset(time.instant.add(time.instant.now(), 20 * time.duration.MilliSecond));
    _ = try callback_state.waitForCount(1, 80 * time.duration.MilliSecond);

    timer.reset(time.instant.add(time.instant.now(), 20 * time.duration.MilliSecond));
    _ = try callback_state.waitForCount(2, 80 * time.duration.MilliSecond);
}

fn immediateFireCase(comptime std: type, comptime time: type, comptime sync: type, comptime task: type) !void {
    const TimerImpl = makeWithTask(std, time, sync, task);
    var callback_state = CallbackState(time, sync){};
    const timer = try TimerImpl.init(std.testing.allocator, CallbackState(time, sync).fire, &callback_state, .{});
    defer timer.deinit();

    timer.reset(time.instant.now());
    _ = try callback_state.waitForCount(1, 50 * time.duration.MilliSecond);
}

fn CallbackState(comptime time: type, comptime sync: type) type {
    return struct {
        mutex: sync.Mutex = .{},
        cond: sync.Condition = .{},
        fire_count: usize = 0,
        last_fire: time.instant.Time = 0,

        const Self = @This();

        pub fn fire(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.mutex.lock();
            self.fire_count += 1;
            self.last_fire = time.instant.now();
            self.cond.broadcast();
            self.mutex.unlock();
        }

        fn waitForCount(self: *Self, expected: usize, timeout: time.duration.Duration) !time.instant.Time {
            const started = time.instant.now();

            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.fire_count < expected) {
                const elapsed = time.instant.sub(time.instant.now(), started);
                if (elapsed >= timeout) return error.TestTimeout;
                const remaining = timeout - elapsed;
                self.cond.timedWait(&self.mutex, @intCast(remaining)) catch |err| switch (err) {
                    error.Timeout => return error.TestTimeout,
                };
            }

            return self.last_fire;
        }

        fn expectStable(self: *Self, expected: usize, duration: time.duration.Duration) !void {
            const started = time.instant.now();

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.fire_count != expected) return error.TestUnexpectedFireCount;

            while (true) {
                const elapsed = time.instant.sub(time.instant.now(), started);
                if (elapsed >= duration) return;
                const remaining = duration - elapsed;
                self.cond.timedWait(&self.mutex, @intCast(remaining)) catch |err| switch (err) {
                    error.Timeout => return,
                };
                if (self.fire_count != expected) return error.TestUnexpectedFireCount;
            }
        }
    };
}
