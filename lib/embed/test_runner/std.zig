//! std compatibility test — exercises Thread, log, posix, net, time, atomic, mem, crypto.
//!
//! Accepts any type with the same shape as std (lib.Thread, lib.log, lib.posix).
//! If this runs with std directly, it proves embed is a proper subset.
//!
//! Usage:
//!   try @import("embed").test_runner.std_compat.run(std);
//!   try @import("embed").test_runner.std_compat.run(embed);

const std = @import("std");
const mem = std.mem;

pub fn run(comptime lib: type) !void {
    const log = lib.log.scoped(.test_runner);

    log.info("=== test_runner start ===", .{});

    try threadTests(lib);
    try mutexTests(lib);
    try conditionTests(lib);
    try rwlockTests(lib);
    try logTests(lib);
    try tcpTest(lib);
    try udpTest(lib);
    try fileTest(lib);
    try seekTests(lib);
    try netUtilTests(lib);
    try timeTests(lib);
    try atomicTests(lib);
    try memTests(lib);
    try collectionsTests(lib);
    try cryptoTests(lib);

    log.info("=== test_runner done ===", .{});
}

// ---------------------------------------------------------------------------
// Thread
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Mutex (tryLock + contention)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Condition
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// RwLock
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Log (all levels + scoped + default)
// ---------------------------------------------------------------------------

fn logTests(comptime lib: type) !void {
    const scoped = lib.log.scoped(.log_test);
    scoped.warn("scoped warn level", .{});
    scoped.info("scoped info level", .{});
    scoped.debug("scoped debug level", .{});

    lib.log.warn("default warn", .{});
    lib.log.info("default info", .{});
    lib.log.debug("default debug", .{});

    lib.log.info("format test: int={} str={s} float={d:.2}", .{ 42, "hello", 3.14 });
}

// ---------------------------------------------------------------------------
// TCP
// ---------------------------------------------------------------------------

fn tcpTest(comptime lib: type) !void {
    const log = lib.log.scoped(.tcp);
    const posix = lib.posix;
    const Ip4Address = lib.net.Ip4Address;

    const server = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(server);
    log.info("tcp server fd={}", .{server});

    const enable: [4]u8 = @bitCast(@as(i32, 1));
    try posix.setsockopt(server, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enable);

    const addr = Ip4Address.init(.{ 127, 0, 0, 1 }, 0);
    try posix.bind(server, @ptrCast(&addr.sa), @sizeOf(@TypeOf(addr.sa)));

    var bound_addr: posix.sockaddr.in = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(server, @ptrCast(&bound_addr), &bound_len);
    const port = lib.mem.bigToNative(u16, bound_addr.port);
    log.info("bound to port {}", .{port});

    try posix.listen(server, 1);
    log.info("listening", .{});

    var poll_fds = [_]posix.pollfd{.{
        .fd = server,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const client_thread = try lib.Thread.spawn(.{}, struct {
        fn connect(comptime p: type, comptime net: type, port_num: u16) void {
            const client = p.socket(p.AF.INET, p.SOCK.STREAM, 0) catch return;
            defer p.close(client);
            const dest = net.Ip4Address.init(.{ 127, 0, 0, 1 }, port_num);
            p.connect(client, @ptrCast(&dest.sa), @sizeOf(@TypeOf(dest.sa))) catch return;
            _ = p.send(client, "hello", 0) catch return;
            var sink: [64]u8 = undefined;
            _ = p.recv(client, &sink, 0) catch return;
        }
    }.connect, .{ posix, lib.net, port });

    const poll_ready = try posix.poll(&poll_fds, 5000);
    log.info("poll ready={}", .{poll_ready});

    var client_addr: posix.sockaddr.in = undefined;
    var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const accepted = try posix.accept(server, @ptrCast(&client_addr), &client_len, 0);
    defer posix.close(accepted);
    log.info("accepted fd={}", .{accepted});

    var buf: [64]u8 = undefined;
    const n = try posix.recv(accepted, &buf, 0);
    log.info("recv: \"{s}\"", .{buf[0..n]});

    _ = try posix.send(accepted, buf[0..n], 0);
    log.info("echoed {d} bytes", .{n});

    try posix.shutdown(accepted, .send);
    log.info("shutdown send", .{});

    client_thread.join();
    log.info("tcp done", .{});
}

// ---------------------------------------------------------------------------
// UDP
// ---------------------------------------------------------------------------

fn udpTest(comptime lib: type) !void {
    const log = lib.log.scoped(.udp);
    const posix = lib.posix;
    const Ip4Address = lib.net.Ip4Address;

    const server = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(server);

    const addr = Ip4Address.init(.{ 127, 0, 0, 1 }, 0);
    try posix.bind(server, @ptrCast(&addr.sa), @sizeOf(@TypeOf(addr.sa)));

    var bound_addr: posix.sockaddr.in = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(server, @ptrCast(&bound_addr), &bound_len);
    const port = lib.mem.bigToNative(u16, bound_addr.port);
    log.info("udp bound to port {}", .{port});

    const client = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(client);

    const dest = Ip4Address.init(.{ 127, 0, 0, 1 }, port);
    _ = try posix.sendto(client, "udp-ping", 0, @ptrCast(&dest.sa), @sizeOf(@TypeOf(dest.sa)));
    log.info("sendto ok", .{});

    var buf: [64]u8 = undefined;
    var src_addr: posix.sockaddr.in = undefined;
    var src_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const n = try posix.recvfrom(server, &buf, 0, @ptrCast(&src_addr), &src_len);
    log.info("recvfrom: \"{s}\"", .{buf[0..n]});

    log.info("udp done", .{});
}

// ---------------------------------------------------------------------------
// File I/O
// ---------------------------------------------------------------------------

fn fileTest(comptime lib: type) !void {
    const log = lib.log.scoped(.file);
    const posix = lib.posix;

    const dir_path = "/tmp/embed_test_runner";
    const file_path = dir_path ++ "/test.txt";

    posix.mkdir(dir_path, 0o755) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    log.info("mkdir ok", .{});

    const fd = try posix.open(file_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    const msg = "hello from test_runner!\n";
    const written = try posix.write(fd, msg);
    log.info("write {d} bytes", .{written});

    const pos = try posix.lseek_CUR_get(fd);
    log.info("lseek_CUR_get pos={}", .{pos});

    try posix.lseek_SET(fd, 0);
    posix.close(fd);

    const rfd = try posix.open(file_path, .{ .ACCMODE = .RDONLY }, 0);
    var buf: [128]u8 = undefined;
    const n = try posix.read(rfd, &buf);
    log.info("read: \"{s}\"", .{buf[0..n]});
    posix.close(rfd);

    try posix.unlink(file_path);
    log.info("file done", .{});
}

// ---------------------------------------------------------------------------
// Seek (lseek_CUR, lseek_END)
// ---------------------------------------------------------------------------

fn seekTests(comptime lib: type) !void {
    const log = lib.log.scoped(.seek);
    const posix = lib.posix;

    const path = "/tmp/embed_test_runner/seek_test.txt";
    const dir_path = "/tmp/embed_test_runner";
    posix.mkdir(dir_path, 0o755) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const fd = try posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    _ = try posix.write(fd, "ABCDEFGHIJ");
    posix.close(fd);

    const fd2 = try posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
    defer posix.close(fd2);

    try posix.lseek_SET(fd2, 3);
    var pos = try posix.lseek_CUR_get(fd2);
    if (pos != 3) return error.SeekSetFailed;
    log.info("lseek_SET(3) -> pos={}", .{pos});

    try posix.lseek_CUR(fd2, 2);
    pos = try posix.lseek_CUR_get(fd2);
    if (pos != 5) return error.SeekCurFailed;
    log.info("lseek_CUR(+2) -> pos={}", .{pos});

    try posix.lseek_CUR(fd2, -1);
    pos = try posix.lseek_CUR_get(fd2);
    if (pos != 4) return error.SeekCurNegFailed;
    log.info("lseek_CUR(-1) -> pos={}", .{pos});

    try posix.lseek_END(fd2, 0);
    pos = try posix.lseek_CUR_get(fd2);
    if (pos != 10) return error.SeekEndFailed;
    log.info("lseek_END(0) -> pos={}", .{pos});

    try posix.lseek_END(fd2, -3);
    pos = try posix.lseek_CUR_get(fd2);
    if (pos != 7) return error.SeekEndNegFailed;
    log.info("lseek_END(-3) -> pos={}", .{pos});

    var buf: [1]u8 = undefined;
    _ = try posix.read(fd2, &buf);
    if (buf[0] != 'H') return error.SeekReadMismatch;
    log.info("read after seek = '{c}'", .{buf[0]});

    try posix.unlink(path);
    log.info("seek done", .{});
}

// ---------------------------------------------------------------------------
// Net utilities (Ip4Address)
// ---------------------------------------------------------------------------

fn netUtilTests(comptime lib: type) !void {
    const log = lib.log.scoped(.net);

    var addr = lib.net.Ip4Address.init(.{ 10, 0, 1, 2 }, 8080);
    if (addr.getPort() != 8080) return error.Ip4PortMismatch;
    log.info("Ip4Address port={}", .{addr.getPort()});

    addr.setPort(9090);
    if (addr.getPort() != 9090) return error.Ip4SetPortFailed;
    log.info("Ip4Address setPort -> port={}", .{addr.getPort()});

    const zero_addr = lib.net.Ip4Address.init(.{ 0, 0, 0, 0 }, 0);
    if (zero_addr.getPort() != 0) return error.Ip4ZeroPortFailed;
    log.info("Ip4Address zero ok", .{});

    log.info("net util done", .{});
}

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

fn timeTests(comptime lib: type) !void {
    const log = lib.log.scoped(.time);

    const t1 = lib.time.milliTimestamp();
    lib.Thread.sleep(10_000_000);
    const t2 = lib.time.milliTimestamp();
    const elapsed = t2 - t1;
    if (elapsed < 5) return error.TimestampTooFast;
    log.info("milliTimestamp elapsed={}ms", .{elapsed});

    if (t1 <= 0) return error.TimestampNonPositive;

    {
        var timer = lib.time.Timer.start();
        lib.Thread.sleep(10_000_000);
        const r1 = timer.read();
        if (r1 == 0) return error.TimerReadZero;
        log.info("Timer.read={}", .{r1});

        const lap_val = timer.lap();
        if (lap_val < r1) return error.TimerLapTooSmall;
        log.info("Timer.lap={}", .{lap_val});

        lib.Thread.sleep(1_000_000);
        const after_lap = timer.read();
        if (after_lap >= lap_val) return error.TimerLapDidNotReset;
        log.info("Timer.lap reset ok, read after lap={}", .{after_lap});

        timer.reset();
        lib.Thread.sleep(1_000_000);
        const after_reset = timer.read();
        if (after_reset >= lap_val) return error.TimerResetFailed;
        log.info("Timer.reset ok, read={}", .{after_reset});
    }

    log.info("time done", .{});
}

// ---------------------------------------------------------------------------
// Atomic
// ---------------------------------------------------------------------------

fn atomicTests(comptime lib: type) !void {
    const log = lib.log.scoped(.atomic);

    var v = lib.atomic.Value(u32).init(0);
    v.store(10, .seq_cst);
    const loaded = v.load(.seq_cst);
    if (loaded != 10) return error.AtomicStoreFailed;
    log.info("store/load ok val={}", .{loaded});

    const prev = v.fetchAdd(5, .seq_cst);
    if (prev != 10) return error.AtomicFetchAddPrevFailed;
    const after = v.load(.seq_cst);
    if (after != 15) return error.AtomicFetchAddFailed;
    log.info("fetchAdd ok prev={} after={}", .{ prev, after });

    const prev2 = v.fetchSub(3, .seq_cst);
    if (prev2 != 15) return error.AtomicFetchSubPrevFailed;
    const after2 = v.load(.seq_cst);
    if (after2 != 12) return error.AtomicFetchSubFailed;
    log.info("fetchSub ok prev={} after={}", .{ prev2, after2 });

    const swapped = v.cmpxchgStrong(12, 99, .seq_cst, .seq_cst);
    if (swapped != null) return error.CmpxchgShouldSucceed;
    if (v.load(.seq_cst) != 99) return error.CmpxchgValueWrong;
    log.info("cmpxchgStrong ok val={}", .{v.load(.seq_cst)});

    const failed = v.cmpxchgStrong(0, 1, .seq_cst, .seq_cst);
    if (failed == null) return error.CmpxchgShouldFail;
    if (failed.? != 99) return error.CmpxchgReturnWrong;
    log.info("cmpxchgStrong fail ok returned={}", .{failed.?});

    const old = v.swap(77, .seq_cst);
    if (old != 99) return error.SwapOldWrong;
    if (v.load(.seq_cst) != 77) return error.SwapNewWrong;
    log.info("swap ok old={} new={}", .{ old, v.load(.seq_cst) });

    log.info("atomic done", .{});
}

// ---------------------------------------------------------------------------
// Mem
// ---------------------------------------------------------------------------

fn memTests(comptime lib: type) !void {
    const log = lib.log.scoped(.mem);

    _ = lib.mem.Allocator;
    log.info("mem.Allocator type present", .{});

    const val: u16 = 0x1234;
    const big = lib.mem.nativeToBig(u16, val);
    const back = lib.mem.bigToNative(u16, big);
    if (back != val) return error.EndianRoundtripFailed;
    log.info("nativeToBig/bigToNative u16 roundtrip ok", .{});

    const val32: u32 = 0xDEADBEEF;
    const big32 = lib.mem.nativeToBig(u32, val32);
    const back32 = lib.mem.bigToNative(u32, big32);
    if (back32 != val32) return error.Endian32RoundtripFailed;
    log.info("nativeToBig/bigToNative u32 roundtrip ok", .{});
}


// ---------------------------------------------------------------------------
// Collections (platform-independent data structures)
// ---------------------------------------------------------------------------

fn collectionsTests(comptime lib: type) !void {
    const log = lib.log.scoped(.collections);
    const allocator = std.testing.allocator;

    // ArrayList
    {
        var list: lib.ArrayList(u32) = .empty;
        defer list.deinit(allocator);
        try list.append(allocator, 10);
        try list.append(allocator, 20);
        try list.append(allocator, 30);
        if (list.items.len != 3) return error.ArrayListLenWrong;
        if (list.items[0] != 10 or list.items[2] != 30) return error.ArrayListValueWrong;
        _ = list.orderedRemove(1);
        if (list.items.len != 2) return error.ArrayListRemoveFailed;
        if (list.items[1] != 30) return error.ArrayListRemoveShiftWrong;
        log.info("ArrayList: append+remove ok, len={}", .{list.items.len});
    }

    // AutoHashMap
    {
        var map = lib.AutoHashMap(u32, []const u8).init(allocator);
        defer map.deinit();
        try map.put(1, "one");
        try map.put(2, "two");
        try map.put(3, "three");
        if (map.count() != 3) return error.HashMapCountWrong;
        const val = map.get(2) orelse return error.HashMapGetFailed;
        if (!mem.eql(u8, val, "two")) return error.HashMapValueWrong;
        _ = map.remove(2);
        if (map.get(2) != null) return error.HashMapRemoveFailed;
        log.info("AutoHashMap: put+get+remove ok, count={}", .{map.count()});
    }

    // StringHashMap
    {
        var map = lib.StringHashMap(i32).init(allocator);
        defer map.deinit();
        try map.put("alpha", 1);
        try map.put("beta", 2);
        if (map.get("alpha") != 1) return error.StringHashMapGetFailed;
        if (!map.contains("beta")) return error.StringHashMapContainsFailed;
        log.info("StringHashMap: put+get+contains ok", .{});
    }

    // AutoArrayHashMap
    {
        var map = lib.AutoArrayHashMap(u32, u32).init(allocator);
        defer map.deinit();
        try map.put(100, 1);
        try map.put(200, 2);
        try map.put(300, 3);
        const keys = map.keys();
        if (keys.len != 3) return error.ArrayHashMapKeysWrong;
        if (keys[0] != 100 or keys[2] != 300) return error.ArrayHashMapOrderWrong;
        log.info("AutoArrayHashMap: insertion-order keys ok, len={}", .{keys.len});
    }

    // BufMap
    {
        var map = lib.BufMap.init(allocator);
        defer map.deinit();
        try map.put("host", "localhost");
        try map.put("port", "8080");
        if (map.count() != 2) return error.BufMapCountWrong;
        const host = map.get("host") orelse return error.BufMapGetFailed;
        if (!mem.eql(u8, host, "localhost")) return error.BufMapValueWrong;
        try map.put("host", "0.0.0.0");
        const updated = map.get("host") orelse return error.BufMapGetFailed2;
        if (!mem.eql(u8, updated, "0.0.0.0")) return error.BufMapUpdateFailed;
        map.remove("port");
        if (map.get("port") != null) return error.BufMapRemoveFailed;
        log.info("BufMap: put+get+update+remove ok, count={}", .{map.count()});
    }

    // BufSet
    {
        var set = lib.BufSet.init(allocator);
        defer set.deinit();
        try set.insert("hello");
        try set.insert("world");
        try set.insert("hello");
        if (set.count() != 2) return error.BufSetCountWrong;
        if (!set.contains("hello")) return error.BufSetContainsFailed;
        set.remove("hello");
        if (set.contains("hello")) return error.BufSetRemoveFailed;
        log.info("BufSet: insert+contains+remove ok, count={}", .{set.count()});
    }

    // PriorityQueue (min-heap)
    {
        var pq = lib.PriorityQueue(u32, void, struct {
            fn cmp(_: void, a: u32, b: u32) std.math.Order {
                return std.math.order(a, b);
            }
        }.cmp).init(allocator, {});
        defer pq.deinit();
        try pq.add(30);
        try pq.add(10);
        try pq.add(20);
        if (pq.count() != 3) return error.PQCountWrong;
        const min = pq.remove();
        if (min != 10) return error.PQMinWrong;
        log.info("PriorityQueue: add+remove min={}, remaining={}", .{ min, pq.count() });
    }

    // DynamicBitSet
    {
        var bs = try lib.DynamicBitSet.initEmpty(allocator, 64);
        defer bs.deinit();
        bs.set(0);
        bs.set(31);
        bs.set(63);
        if (bs.count() != 3) return error.DynBitSetCountWrong;
        if (!bs.isSet(31)) return error.DynBitSetIsSetFailed;
        bs.unset(31);
        if (bs.isSet(31)) return error.DynBitSetUnsetFailed;
        log.info("DynamicBitSet: set+unset+count ok, count={}", .{bs.count()});
    }

    // StaticBitSet
    {
        var bs = lib.StaticBitSet(128).initEmpty();
        bs.set(0);
        bs.set(64);
        bs.set(127);
        if (bs.count() != 3) return error.StaticBitSetCountWrong;
        bs.toggle(64);
        if (bs.isSet(64)) return error.StaticBitSetToggleFailed;
        log.info("StaticBitSet: set+toggle+count ok", .{});
    }

    // DoublyLinkedList (intrusive)
    {
        const DLL = lib.DoublyLinkedList;
        var list = DLL{};
        var n1 = DLL.Node{};
        var n2 = DLL.Node{};
        var n3 = DLL.Node{};
        list.append(&n1);
        list.append(&n2);
        list.append(&n3);
        if (list.len() != 3) return error.DLLLenWrong;
        list.remove(&n2);
        if (list.len() != 2) return error.DLLRemoveFailed;
        if (list.first != &n1 or list.last != &n3) return error.DLLOrderWrong;
        log.info("DoublyLinkedList: append+remove ok, len={}", .{list.len()});
    }

    // SinglyLinkedList (intrusive)
    {
        const SLL = lib.SinglyLinkedList;
        var list = SLL{};
        var n1 = SLL.Node{};
        var n2 = SLL.Node{};
        var n3 = SLL.Node{};
        list.prepend(&n3);
        list.prepend(&n2);
        list.prepend(&n1);
        if (list.len() != 3) return error.SLLLenWrong;
        if (list.first != &n1) return error.SLLOrderWrong;
        _ = list.popFirst();
        if (list.first != &n2) return error.SLLPopFailed;
        log.info("SinglyLinkedList: prepend+popFirst ok, len={}", .{list.len()});
    }

    // EnumArray
    {
        const Color = enum { red, green, blue };
        var arr = lib.EnumArray(Color, u32).initFill(0);
        arr.set(.red, 10);
        arr.set(.blue, 30);
        if (arr.get(.red) != 10) return error.EnumArrayGetWrong;
        if (arr.get(.green) != 0) return error.EnumArrayDefaultWrong;
        if (arr.get(.blue) != 30) return error.EnumArrayGetWrong2;
        log.info("EnumArray: set+get ok", .{});
    }

    // EnumSet
    {
        const Fruit = enum { apple, banana, cherry, date };
        var set = lib.EnumSet(Fruit).initEmpty();
        set.insert(.apple);
        set.insert(.cherry);
        if (set.count() != 2) return error.EnumSetCountWrong;
        if (!set.contains(.apple)) return error.EnumSetContainsFailed;
        set.remove(.apple);
        if (set.contains(.apple)) return error.EnumSetRemoveFailed;
        log.info("EnumSet: insert+contains+remove ok", .{});
    }

    // StaticStringMap
    {
        const map = lib.StaticStringMap(u32).initComptime(.{
            .{ "foo", 1 },
            .{ "bar", 2 },
            .{ "baz", 3 },
        });
        if ((map.get("foo") orelse return error.SSMGetFailed) != 1) return error.SSMValueWrong;
        if ((map.get("baz") orelse return error.SSMGetFailed2) != 3) return error.SSMValueWrong2;
        if (map.get("missing") != null) return error.SSMMissingShouldBeNull;
        log.info("StaticStringMap: initComptime+get ok", .{});
    }

    // MultiArrayList
    {
        const Item = struct { x: u32, y: f32 };
        var mal = lib.MultiArrayList(Item){};
        defer mal.deinit(allocator);
        try mal.append(allocator, .{ .x = 1, .y = 1.0 });
        try mal.append(allocator, .{ .x = 2, .y = 2.0 });
        try mal.append(allocator, .{ .x = 3, .y = 3.0 });
        if (mal.len != 3) return error.MALLenWrong;
        const xs = mal.items(.x);
        if (xs[0] != 1 or xs[2] != 3) return error.MALSliceWrong;
        log.info("MultiArrayList: append+items ok, len={}", .{mal.len});
    }

    // BitStack
    {
        var bs = lib.BitStack.init(allocator);
        defer bs.deinit();
        try bs.push(1);
        try bs.push(0);
        try bs.push(1);
        const top = bs.pop();
        if (top != 1) return error.BitStackPopWrong;
        const next = bs.peek();
        if (next != 0) return error.BitStackPeekWrong;
        log.info("BitStack: push+pop+peek ok", .{});
    }

    log.info("collections done", .{});
}

// ---------------------------------------------------------------------------
// Crypto
// ---------------------------------------------------------------------------

fn cryptoTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);

    try hashTests(lib);
    try hmacTests(lib);
    try aeadTests(lib);
    try randomTests(lib);
    try hkdfTests(lib);
    try ed25519Tests(lib);
    try ecdsaTests(lib);
    try x25519Tests(lib);
    try eccTests(lib);
    try aesBlockTests(lib);
    try certificateTests(lib);

    log.info("crypto done", .{});
}

fn hashTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const crypto = lib.crypto;

    inline for (.{
        .{ crypto.hash.sha2.Sha256, 32, "sha256" },
        .{ crypto.hash.sha2.Sha384, 48, "sha384" },
        .{ crypto.hash.sha2.Sha512, 64, "sha512" },
    }) |entry| {
        const H = entry[0];
        const expected_len = entry[1];
        const name = entry[2];

        if (H.digest_length != expected_len) return error.HashDigestLenMismatch;

        var out: [H.digest_length]u8 = undefined;
        H.hash("hello", &out, .{});
        if (out[0] == 0 and out[1] == 0 and out[2] == 0 and out[3] == 0)
            return error.HashOutputAllZero;

        var h = H.init(.{});
        h.update("hel");
        h.update("lo");
        var out2: [H.digest_length]u8 = undefined;

        const peeked = h.peek();

        h.final(&out2);

        if (!mem.eql(u8, &out, &out2)) return error.HashStreamingMismatch;
        if (!mem.eql(u8, &peeked, &out)) return error.HashPeekMismatch;

        log.info("hash.sha2.{s}: digest_length={} one-shot+streaming+peek ok", .{ name, H.digest_length });
    }
}

fn hmacTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const crypto = lib.crypto;

    inline for (.{
        .{ crypto.auth.hmac.sha2.HmacSha256, 32, "HmacSha256" },
        .{ crypto.auth.hmac.sha2.HmacSha384, 48, "HmacSha384" },
        .{ crypto.auth.hmac.sha2.HmacSha512, 64, "HmacSha512" },
    }) |entry| {
        const H = entry[0];
        const expected_len = entry[1];
        const name = entry[2];

        if (H.mac_length != expected_len) return error.HmacMacLenMismatch;

        const key = "secret-key";
        const msg = "hello world";

        var out1: [H.mac_length]u8 = undefined;
        H.create(&out1, msg, key);

        var ctx = H.init(key);
        ctx.update("hello ");
        ctx.update("world");
        var out2: [H.mac_length]u8 = undefined;
        ctx.final(&out2);

        if (!mem.eql(u8, &out1, &out2)) return error.HmacStreamingMismatch;

        log.info("auth.hmac.sha2.{s}: mac_length={} create+streaming ok", .{ name, H.mac_length });
    }
}

fn aeadTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const crypto = lib.crypto;

    inline for (.{
        .{ crypto.aead.aes_gcm.Aes128Gcm, "Aes128Gcm" },
        .{ crypto.aead.aes_gcm.Aes256Gcm, "Aes256Gcm" },
        .{ crypto.aead.chacha_poly.ChaCha20Poly1305, "ChaCha20Poly1305" },
    }) |entry| {
        const A = entry[0];
        const name = entry[1];

        var key: [A.key_length]u8 = undefined;
        var nonce: [A.nonce_length]u8 = undefined;
        @memset(&key, 0x42);
        @memset(&nonce, 0x24);

        const plaintext = "crypto test msg!";
        var ciphertext: [plaintext.len]u8 = undefined;
        var tag: [A.tag_length]u8 = undefined;

        A.encrypt(&ciphertext, &tag, plaintext, "", nonce, key);

        var decrypted: [plaintext.len]u8 = undefined;
        try A.decrypt(&decrypted, &ciphertext, tag, "", nonce, key);

        if (!mem.eql(u8, plaintext, &decrypted)) return error.AeadDecryptMismatch;

        tag[0] ^= 0xff;
        if (A.decrypt(&decrypted, &ciphertext, tag, "", nonce, key)) |_| {
            return error.AeadShouldFailBadTag;
        } else |_| {}

        log.info("aead.{s}: encrypt+decrypt+auth ok", .{name});
    }
}

fn randomTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);

    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    lib.crypto.random.bytes(&buf1);
    lib.crypto.random.bytes(&buf2);

    if (mem.eql(u8, &buf1, &buf2)) return error.RandomNotRandom;

    log.info("random: 32 bytes x2 differ ok", .{});
}

fn hkdfTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const crypto = lib.crypto;

    inline for (.{
        .{ crypto.kdf.hkdf.HkdfSha256, "HkdfSha256" },
    }) |entry| {
        const H = entry[0];
        const name = entry[1];

        const salt = "salt-value";
        const ikm = "input-keying-material";
        const prk = H.extract(salt, ikm);

        if (prk.len != H.prk_length) return error.HkdfPrkLenMismatch;

        var okm: [64]u8 = undefined;
        H.expand(&okm, "info", prk);

        var all_zero = true;
        for (okm) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) return error.HkdfOutputAllZero;

        log.info("kdf.hkdf.{s}: extract+expand ok", .{name});
    }
}

fn ed25519Tests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const Ed = lib.crypto.sign.Ed25519;

    if (Ed.noise_length != 32) return error.Ed25519NoiseLenWrong;
    if (Ed.KeyPair.seed_length != 32) return error.Ed25519SeedLenWrong;
    if (Ed.Signature.encoded_length != 64) return error.Ed25519SigLenWrong;
    if (Ed.PublicKey.encoded_length != 32) return error.Ed25519PkLenWrong;
    if (Ed.SecretKey.encoded_length != 64) return error.Ed25519SkLenWrong;

    const kp = Ed.KeyPair.generate();
    const msg = "sign this message";
    const sig = kp.sign(msg, null) catch return error.Ed25519SignFailed;

    sig.verify(msg, kp.public_key) catch return error.Ed25519VerifyFailed;

    const sig_bytes = sig.toBytes();
    const sig2 = Ed.Signature.fromBytes(sig_bytes);
    if (!mem.eql(u8, &sig_bytes, &sig2.toBytes())) return error.Ed25519SigRoundtripFailed;

    log.info("sign.Ed25519: generate+sign+verify+roundtrip ok", .{});
}

fn ecdsaTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const crypto = lib.crypto;

    inline for (.{
        .{ crypto.sign.ecdsa.EcdsaP256Sha256, "EcdsaP256Sha256" },
        .{ crypto.sign.ecdsa.EcdsaP384Sha384, "EcdsaP384Sha384" },
    }) |entry| {
        const E = entry[0];
        const name = entry[1];

        _ = E.KeyPair.seed_length;
        _ = E.Signature.encoded_length;
        _ = E.PublicKey.compressed_sec1_encoded_length;
        _ = E.PublicKey.uncompressed_sec1_encoded_length;
        _ = E.SecretKey.encoded_length;

        const sig_bytes = [_]u8{0} ** E.Signature.encoded_length;
        const sig = E.Signature.fromBytes(sig_bytes);
        const rt = sig.toBytes();
        if (!mem.eql(u8, &sig_bytes, &rt)) return error.EcdsaSigRoundtripFailed;

        log.info("sign.ecdsa.{s}: constants+roundtrip ok", .{name});
    }
}

fn x25519Tests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const X = lib.crypto.dh.X25519;

    if (X.secret_length != 32) return error.X25519SecretLenWrong;
    if (X.public_length != 32) return error.X25519PublicLenWrong;
    if (X.shared_length != 32) return error.X25519SharedLenWrong;
    if (X.seed_length != 32) return error.X25519SeedLenWrong;

    const kp_a = X.KeyPair.generate();
    const kp_b = X.KeyPair.generate();

    const shared_a = try X.scalarmult(kp_a.secret_key, kp_b.public_key);
    const shared_b = try X.scalarmult(kp_b.secret_key, kp_a.public_key);

    if (!mem.eql(u8, &shared_a, &shared_b)) return error.X25519SharedMismatch;

    const recovered = try X.recoverPublicKey(kp_a.secret_key);
    if (!mem.eql(u8, &recovered, &kp_a.public_key)) return error.X25519RecoverMismatch;

    log.info("dh.X25519: generate+scalarmult+recoverPublicKey ok", .{});
}

fn eccTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const P = lib.crypto.ecc.P256;

    _ = P.Fe;
    _ = P.scalar;
    _ = P.basePoint;

    log.info("ecc.P256: Fe+scalar+basePoint present", .{});
}

fn aesBlockTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const aes = lib.crypto.core.aes;

    inline for (.{
        .{ aes.Aes128, 128, "Aes128" },
        .{ aes.Aes256, 256, "Aes256" },
    }) |entry| {
        const A = entry[0];
        const expected_bits = entry[1];
        const name = entry[2];

        if (A.key_bits != expected_bits) return error.AesKeyBitsMismatch;

        var key: [A.key_bits / 8]u8 = undefined;
        @memset(&key, 0xAB);

        const plaintext: [16]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        var encrypted: [16]u8 = undefined;
        var decrypted: [16]u8 = undefined;

        const enc_ctx = A.initEnc(key);
        enc_ctx.encrypt(&encrypted, &plaintext);

        const dec_ctx = A.initDec(key);
        dec_ctx.decrypt(&decrypted, &encrypted);

        if (!mem.eql(u8, &plaintext, &decrypted)) return error.AesBlockRoundtripFailed;

        log.info("core.aes.{s}: encrypt+decrypt block ok", .{name});
    }
}

fn certificateTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const Cert = lib.crypto.Certificate;

    _ = Cert.Version;
    _ = Cert.Algorithm;
    _ = Cert.AlgorithmCategory;
    _ = Cert.NamedCurve;
    _ = Cert.ExtensionId;
    _ = Cert.Parsed;
    _ = Cert.ParseError;
    _ = Cert.Bundle;

    log.info("Certificate: all types present", .{});
}

// Run the full test suite against std directly, proving that embed's
// API surface is a proper subset of std. If this passes, any code written
// against embed can switch to std with zero modifications.
test "compact_test" {
    try run(std);
}
