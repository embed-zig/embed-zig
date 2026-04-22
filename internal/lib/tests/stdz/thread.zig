const stdz = @import("stdz");
const testing_mod = @import("testing");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("spawn_clamps_stack_size_to_page_size", testing_mod.TestRunner.fromFn(lib, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try spawnClampsStackSizeToPageSize(lib);
                }
            }.run));
            t.run("condition_make_accepts_matching_mutex_impl", testing_mod.TestRunner.fromFn(lib, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try conditionMakeCase(lib);
                }
            }.run));
            t.run("thread_api", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try threadTests(lib);
                }
            }.run));
            t.run("mutex", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try mutexTests(lib);
                }
            }.run));
            t.run("condition", testing_mod.TestRunner.fromFn(lib, 48 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try conditionTests(lib);
                }
            }.run));
            t.run("rwlock", testing_mod.TestRunner.fromFn(lib, 48 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try rwlockTests(lib);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_mod.TestRunner.make(Runner).new(runner);
}

fn conditionMakeCase(comptime lib: type) !void {
    _ = lib;
    try conditionMakeAcceptsMatchingMutexImpl();
}

fn spawnClampsStackSizeToPageSize(comptime lib: type) !void {
    const ThreadApi = @import("stdz").Thread;
    const Heap = struct {
        pub fn pageSize() usize {
            return 4096;
        }
    };

    const MutexImpl = struct {
        pub fn lock(_: *@This()) void {}
        pub fn unlock(_: *@This()) void {}
        pub fn tryLock(_: *@This()) bool {
            return true;
        }
    };

    const ConditionImpl = struct {
        pub fn wait(_: *@This(), _: *MutexImpl) void {}
        pub fn timedWait(_: *@This(), _: *MutexImpl, _: u64) error{Timeout}!void {}
        pub fn signal(_: *@This()) void {}
        pub fn broadcast(_: *@This()) void {}
    };

    const RwLockImpl = struct {
        pub fn lockShared(_: *@This()) void {}
        pub fn unlockShared(_: *@This()) void {}
        pub fn lock(_: *@This()) void {}
        pub fn unlock(_: *@This()) void {}
        pub fn tryLockShared(_: *@This()) bool {
            return true;
        }
        pub fn tryLock(_: *@This()) bool {
            return true;
        }
    };

    const Impl = struct {
        pub const default_stack_size: usize = 8192;
        pub const Id = usize;
        pub const max_name_len: usize = 8;
        pub const Mutex = MutexImpl;
        pub const Condition = ConditionImpl;
        pub const RwLock = RwLockImpl;

        pub var last_stack_size: usize = 0;

        pub fn spawn(config: ThreadApi.SpawnConfig, comptime f: anytype, args: anytype) ThreadApi.SpawnError!@This() {
            _ = f;
            _ = args;
            last_stack_size = config.stack_size;
            return .{};
        }

        pub fn join(_: @This()) void {}
        pub fn detach(_: @This()) void {}
        pub fn yield() ThreadApi.YieldError!void {}
        pub fn sleep(_: u64) void {}
        pub fn getCpuCount() ThreadApi.CpuCountError!usize {
            return 1;
        }
        pub fn getCurrentId() Id {
            return 0;
        }
        pub fn setName(_: []const u8) ThreadApi.SetNameError!void {}
        pub fn getName(_: *[max_name_len:0]u8) ThreadApi.GetNameError!?[]const u8 {
            return null;
        }
    };

    const Thread = ThreadApi.make(Impl, Heap);

    _ = try Thread.spawn(.{ .stack_size = 1 }, struct {
        fn run() void {}
    }.run, .{});

    try lib.testing.expectEqual(@as(usize, 4096), Impl.last_stack_size);
}

fn conditionMakeAcceptsMatchingMutexImpl() !void {
    const ConditionApi = @import("stdz").Thread.Condition;
    const MutexImpl = struct {
        state: u8 = 0,
    };
    const ConditionImpl = struct {
        pub fn wait(_: *@This(), _: *MutexImpl) void {}
        pub fn timedWait(_: *@This(), _: *MutexImpl, _: u64) error{Timeout}!void {}
        pub fn signal(_: *@This()) void {}
        pub fn broadcast(_: *@This()) void {}
    };

    const Condition = ConditionApi.make(ConditionImpl);
    const Mutex = struct {
        impl: MutexImpl = .{},
    };

    var cond: Condition = .{};
    var mutex: Mutex = .{};

    cond.wait(&mutex);
    try cond.timedWait(&mutex, 1);
    cond.signal();
    cond.broadcast();
}

fn threadTests(comptime lib: type) !void {
    _ = try lib.Thread.getCpuCount();
    _ = lib.Thread.getCurrentId();

    var t = try lib.Thread.spawn(.{}, struct {
        fn work(l: type) void {
            _ = l;
        }
    }.work, .{lib});
    t.join();

    try lib.Thread.yield();
    lib.Thread.sleep(1_000_000);

    {
        var counter = lib.atomic.Value(u32).init(0);
        const N = 4;
        var threads: [N]lib.Thread = undefined;
        for (0..N) |i| {
            threads[i] = try lib.Thread.spawn(.{}, struct {
                fn inc(c: *lib.atomic.Value(u32)) void {
                    _ = c.fetchAdd(1, .seq_cst);
                }
            }.inc, .{&counter});
        }
        for (0..N) |i| threads[i].join();
        const final = counter.load(.seq_cst);
        if (final != N) return error.ThreadCountMismatch;
    }

    {
        var detached = try lib.Thread.spawn(.{}, struct {
            fn noop() void {}
        }.noop, .{});
        detached.detach();
    }
}

fn mutexTests(comptime lib: type) !void {
    var mutex = lib.Thread.Mutex{};

    mutex.lock();
    mutex.unlock();

    mutex.lock();
    const got = mutex.tryLock();
    if (got) return error.TryLockShouldFail;
    mutex.unlock();

    const got2 = mutex.tryLock();
    if (!got2) return error.TryLockShouldSucceed;
    mutex.unlock();

    {
        var shared: u64 = 0;
        const N = 4;
        const ITERS = 1000;
        var threads: [N]lib.Thread = undefined;
        for (0..N) |i| {
            threads[i] = try lib.Thread.spawn(.{}, struct {
                fn work(m: *lib.Thread.Mutex, s: *u64) void {
                    for (0..ITERS) |_| {
                        m.lock();
                        s.* += 1;
                        m.unlock();
                    }
                }
            }.work, .{ &mutex, &shared });
        }
        for (0..N) |i| threads[i].join();
        if (shared != N * ITERS) return error.MutexContentionFailed;
    }
}

fn conditionTests(comptime lib: type) !void {
    const Shared = struct {
        mutex: lib.Thread.Mutex = .{},
        cond: lib.Thread.Condition = .{},
        ready: bool = false,
        value: u32 = 0,
    };

    var shared = Shared{};

    const waiter = try lib.Thread.spawn(.{}, struct {
        fn wait(s: *Shared) void {
            s.mutex.lock();
            while (!s.ready) s.cond.wait(&s.mutex);
            s.value = 42;
            s.mutex.unlock();
        }
    }.wait, .{&shared});

    lib.Thread.sleep(5_000_000);

    shared.mutex.lock();
    shared.ready = true;
    shared.mutex.unlock();
    shared.cond.signal();

    waiter.join();
    if (shared.value != 42) return error.ConditionValueMismatch;

    {
        const BShared = struct {
            mutex: lib.Thread.Mutex = .{},
            cond: lib.Thread.Condition = .{},
            go: bool = false,
            count: u32 = 0,
        };
        var bs = BShared{};
        const N = 3;
        var threads: [N]lib.Thread = undefined;
        for (0..N) |i| {
            threads[i] = try lib.Thread.spawn(.{}, struct {
                fn wait(s: *BShared) void {
                    s.mutex.lock();
                    while (!s.go) s.cond.wait(&s.mutex);
                    s.count += 1;
                    s.mutex.unlock();
                }
            }.wait, .{&bs});
        }

        lib.Thread.sleep(5_000_000);

        bs.mutex.lock();
        bs.go = true;
        bs.mutex.unlock();
        bs.cond.broadcast();

        for (0..N) |i| threads[i].join();
        if (bs.count != N) return error.BroadcastCountMismatch;
    }
}

fn rwlockTests(comptime lib: type) !void {
    var rw = lib.Thread.RwLock{};

    rw.lockShared();
    rw.unlockShared();

    rw.lock();
    rw.unlock();

    {
        const got = rw.tryLockShared();
        if (!got) return error.TryLockSharedFailed;
        rw.unlockShared();
    }

    {
        const got = rw.tryLock();
        if (!got) return error.TryLockExclusiveFailed;
        rw.unlock();
    }

    {
        rw.lock();
        const got = rw.tryLockShared();
        if (got) rw.unlockShared();
        rw.unlock();
    }

    {
        var data: u64 = 0;
        var mutex_rw = lib.Thread.RwLock{};
        const READERS = 4;
        const WRITER_ITERS = 100;

        const writer = try lib.Thread.spawn(.{}, struct {
            fn work(rw_ptr: *lib.Thread.RwLock, d: *u64) void {
                for (0..WRITER_ITERS) |_| {
                    rw_ptr.lock();
                    d.* += 1;
                    rw_ptr.unlock();
                }
            }
        }.work, .{ &mutex_rw, &data });

        var readers: [READERS]lib.Thread = undefined;
        for (0..READERS) |i| {
            readers[i] = try lib.Thread.spawn(.{}, struct {
                fn read(rw_ptr: *lib.Thread.RwLock, d: *u64) void {
                    for (0..WRITER_ITERS) |_| {
                        rw_ptr.lockShared();
                        _ = d.*;
                        rw_ptr.unlockShared();
                    }
                }
            }.read, .{ &mutex_rw, &data });
        }

        writer.join();
        for (0..READERS) |i| readers[i].join();
        if (data != WRITER_ITERS) return error.RwLockDataMismatch;
    }
}
