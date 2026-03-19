//! std compatibility test — exercises Thread, log, posix, net, time, atomic, mem.
//!
//! Accepts any type with the same shape as std (lib.Thread, lib.log, lib.posix).
//! If this runs with std directly, it proves embed is a proper subset.
//!
//! Usage:
//!   try @import("embed").test_runner.std_compat.run(std);
//!   try @import("embed").test_runner.std_compat.run(embed);

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


// Run the full test suite against std directly, proving that embed's
// API surface is a proper subset of std. If this passes, any code written
// against embed can switch to std with zero modifications.
test "compact_test" {
    const std = @import("std");
    try run(std);
}