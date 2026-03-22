pub fn run(comptime lib: type) !void {
    try threadTests(lib);
    try mutexTests(lib);
    try conditionTests(lib);
    try rwlockTests(lib);
}

fn threadTests(comptime lib: type) !void {
    const log = lib.log.scoped(.thread);

    const cpu_count = try lib.Thread.getCpuCount();
    log.info("cpu count: {}", .{cpu_count});

    const tid = lib.Thread.getCurrentId();
    log.info("thread id: {}", .{tid});

    var t = try lib.Thread.spawn(.{}, struct {
        fn work(l: type) void {
            l.log.scoped(.worker).info("worker running", .{});
        }
    }.work, .{lib});
    t.join();

    try lib.Thread.yield();
    log.debug("yield ok", .{});

    lib.Thread.sleep(1_000_000);
    log.debug("sleep 1ms ok", .{});

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
        log.info("multi-thread counter={}", .{final});
    }

    {
        var detached = try lib.Thread.spawn(.{}, struct {
            fn noop() void {}
        }.noop, .{});
        detached.detach();
        log.debug("detach ok", .{});
    }
}

fn mutexTests(comptime lib: type) !void {
    const log = lib.log.scoped(.mutex);

    var mutex = lib.Thread.Mutex{};

    mutex.lock();
    log.debug("mutex locked", .{});
    mutex.unlock();

    mutex.lock();
    const got = mutex.tryLock();
    if (got) return error.TryLockShouldFail;
    log.debug("tryLock while held = false", .{});
    mutex.unlock();

    const got2 = mutex.tryLock();
    if (!got2) return error.TryLockShouldSucceed;
    mutex.unlock();
    log.debug("tryLock while free = true", .{});

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
        log.info("mutex contention: {} increments ok", .{shared});
    }
}

fn conditionTests(comptime lib: type) !void {
    const log = lib.log.scoped(.condition);

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
    log.info("signal ok, value={}", .{shared.value});

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
        log.info("broadcast ok, count={}", .{bs.count});
    }
}

fn rwlockTests(comptime lib: type) !void {
    const log = lib.log.scoped(.rwlock);

    var rw = lib.Thread.RwLock{};

    rw.lockShared();
    log.debug("shared lock acquired", .{});
    rw.unlockShared();

    rw.lock();
    log.debug("exclusive lock acquired", .{});
    rw.unlock();

    {
        const got = rw.tryLockShared();
        if (!got) return error.TryLockSharedFailed;
        rw.unlockShared();
        log.debug("tryLockShared ok", .{});
    }

    {
        const got = rw.tryLock();
        if (!got) return error.TryLockExclusiveFailed;
        rw.unlock();
        log.debug("tryLock ok", .{});
    }

    {
        rw.lock();
        const got = rw.tryLockShared();
        if (got) {
            rw.unlockShared();
            log.debug("tryLockShared while locked = true (impl allows)", .{});
        } else {
            log.debug("tryLockShared while locked = false", .{});
        }
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
        log.info("concurrent r/w ok, data={}", .{data});
    }
}
