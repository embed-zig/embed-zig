const embed = @import("embed");
const testing_mod = @import("testing");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            runImpl(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_mod.TestRunner.make(Runner).new(runner);
}

fn runImpl(comptime lib: type) !void {
    try threadTests(lib);
    try mutexTests(lib);
    try conditionTests(lib);
    try rwlockTests(lib);
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
