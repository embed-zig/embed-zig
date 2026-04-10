//! Channel 行为一致性测试运行器
//!
//! 本文件接受一个已经构造好的 Channel 类型工厂（通过 comptime 参数传入），
//! 内部直接经由 `(u32)` 实例化测试对象，
//! 运行全部测试，验证其行为与 Go channel 语义一致。
//!
//! 注意：本 runner 只使用 channel contract 暴露的 API（init/deinit/send/recv/recvTimeout/close），
//! 不依赖 trySend/tryRecv/readFd/writeFd 等 impl 特有方法。
//! 那些 impl 特有的行为（如 readiness/selector 可观测性）应在 impl 自己的测试中覆盖。
//!
//! 用法示例：
//! ```
//! try @import("sync").test_runner.integration.channel.run(
//!     embed,
//!     @import("sync").Channel(platform.Channel),
//! );
//! ```
//!
//! `make(...)` 路径会透传调用方提供的 allocator；直接 `run(...)` 时才回落到
//! `lib.testing.allocator`。
//!
//! 以下是当前 runner 覆盖的测试要点清单：
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  〇、无缓冲 channel（capacity=0）— Go rendezvous 语义
//! ═══════════════════════════════════════════════════════════
//!
//!  U1. capacity=0 时允许创建 channel（unbuffered）
//!  U2. unbuffered send 阻塞直到有 receiver 取走
//!  U3. unbuffered recv 阻塞直到有 sender 提供
//!  U4. unbuffered 握手后值正确传递
//!  U5. unbuffered 多轮 send/recv 握手不死锁
//!  U6. unbuffered close 唤醒阻塞的 recv，返回 ok=false
//!  U7. unbuffered close 唤醒阻塞的 send，返回 ok=false
//!  U8. unbuffered close 后 send 返回 ok=false
//!  U9. unbuffered close 后 recv 返回 ok=false
//!  U10. unbuffered SPSC 并发不丢消息
//!  U11. unbuffered MPSC 并发不丢消息
//!  U12. unbuffered deinit 无泄漏
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  一、初始化与基本属性
//! ═══════════════════════════════════════════════════════════
//!
//!  1. capacity=1 时允许创建 channel（单槽位缓冲）
//!  2. capacity>1 时允许创建 channel（多槽位缓冲，如 64, 1024）
//!  3. 新建有缓冲 channel 的初始状态正确：
//!     send 后可 recv，值一致
//!  4. deinit 后资源释放干净（allocator 无泄漏）
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  二、发送与接收的基本语义
//! ═══════════════════════════════════════════════════════════
//!
//!  5.  单个元素 send 后可被 recv 读出，ok=true，值与写入一致
//!  6.  多个元素发送后按 FIFO 顺序读取，严格先进先出
//!  7.  环形缓冲区绕回后仍保持 FIFO：
//!      head/tail 指针绕回不影响顺序
//!  8.  发送和接收交替进行时状态正确：
//!      长度、顺序一致
//!  9.  recv 在有数据时返回 ok=true，拿到正确值
//!  10. send 在有空位时返回 ok=true
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  三、有缓冲 channel 缓冲区边界
//! ═══════════════════════════════════════════════════════════
//!
//!  11. 缓冲区未满时 send 立即返回 ok=true，不阻塞
//!  12. 恰好填满缓冲区（send capacity 次）后，所有 send 都返回 ok=true
//!  13. 缓冲区满时 send 阻塞：
//!      启动 send 线程，短暂等待后确认它仍未返回
//!  14. 缓冲区满后，另一线程 recv 取走一个值，阻塞的 send 被唤醒并成功写入
//!  15. 缓冲区为空时 recv 阻塞：
//!      启动 recv 线程，短暂等待后确认它仍未返回
//!  16. 缓冲区为空后，另一线程 send 写入一个值，阻塞的 recv 被唤醒并拿到值
//!  17. capacity=1 时行为正确：
//!      send 一个后满，再 send 阻塞；recv 后腾出空位
//!  18. ring buffer 回绕：
//!      send/recv 交替超过 capacity 次，head/tail 正确回绕，数据不错乱
//!  19. 填满再全部读空后再次填满排空，token 数量一致，不丢不多
//!  20. 同一个 channel 反复填满-排空多轮，行为始终正确，状态不残留
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  四、close 的 Go 语义
//! ═══════════════════════════════════════════════════════════
//!
//! Go 语义里 close 后 send 是 panic，double close 也是 panic。
//! 本 contract 只约束 send after close 返回 ok=false，因此这里锁定的是
//! send/recv after close 的可观测语义；double close 不属于当前 runner 的断言范围。
//!
//!  21. close 一个未关闭 channel 成功，channel 进入 closed 状态
//!  22. close 后 send 返回 ok=false，不能静默成功
//!  23. close 后多次 send 均返回 ok=false（幂等）
//!  24. close 后，缓冲中已有的数据仍然可以按 FIFO 继续读完（ok=true）
//!  25. close 后，缓冲耗尽时 recv 返回 ok=false，不再阻塞，不再返回旧值
//!  26. close 后对空 closed channel 连续多次 recv 都返回 ok=false（行为稳定）
//!  27. close 后 send+recv 排空完整流程：先 send 若干 -> close -> recv 全部 -> ok=false
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  五、阻塞路径与唤醒
//! ═══════════════════════════════════════════════════════════
//!
//!  28. 空 channel 上阻塞 recv，当有发送到来时被正确唤醒，收到值 ok=true
//!  29. 满缓冲 channel 上阻塞 send，当有接收到来时被正确唤醒，发送成功
//!  30. 空 channel 上阻塞 recv，close 后必须被唤醒，返回 ok=false，不能永久卡死
//!  31. 满缓冲 channel 上阻塞 send，close 后必须被唤醒，返回 ok=false
//!  32. close 唤醒所有（多个）阻塞在 recv 上的线程，它们都拿到 ok=false
//!  33. close 唤醒所有（多个）阻塞在 send 上的线程，它们都拿到 ok=false
//!  34. 交替 send/recv 大量轮次（≥10000），不死锁、不丢数据
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  六、并发正确性
//! ═══════════════════════════════════════════════════════════
//!
//!  35. 单生产者单消费者并发下不丢消息，发送数量与接收数量一致
//!  36. 多生产者单消费者并发下不丢消息，总数正确，无覆盖
//!  37. 单生产者多消费者并发下不重复投递，每个元素只被一个消费者拿到一次
//!  38. 多生产者多消费者并发下保持数据完整性：无重复、无丢失、无越界、无死锁
//!  39. 并发 close 与 recv 竞态：已有数据可读完，之后 ok=false
//!  40. 并发 close 与 send 竞态：send 返回 ok=true 或 ok=false，不能静默丢失
//!  41. 高并发压力：M 个生产者 × K 个消费者并发跑，验证无 race、无 panic
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  七、资源安全
//! ═══════════════════════════════════════════════════════════
//!
//!  说明：这些 case 主要覆盖常见 close/deinit 生命周期不会 panic 或 hang，
//!  并在默认测试分配器下不留下明显 allocator 泄漏；它们不是独立的 leak detector。
//!
//!  42. 正常 send/recv/deinit 路径可正常收尾
//!  43. 带未消费缓冲数据直接 deinit 可正常收尾
//!  44. close 后 deinit 可正常收尾
//!  45. 快速连续 close + recv 不 panic、不 hang
//!  46. 快速连续 close + send 不 panic、不 hang

const embed = @import("embed");
const testing_api = @import("testing");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            const Suite = ChannelSuite(lib, Channel);
            return Suite.runUnderT(t, allocator);
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}

pub fn run(comptime lib: type, comptime Channel: fn (type) type) !void {
    try runImpl(lib, Channel, lib.testing.allocator);
}

fn runImpl(comptime lib: type, comptime Channel: fn (type) type, allocator: lib.mem.Allocator) !void {
    const Runner = ChannelSuite(lib, Channel);
    return Runner.exec(allocator);
}

fn ChannelSuite(comptime lib: type, comptime Channel: fn (type) type) type {
    const Ch = Channel(u32);
    const Thread = lib.Thread;
    const Allocator = lib.mem.Allocator;
    const Atomic = lib.atomic.Value;
    const time = lib.time;
    const run_log = lib.log.scoped(.test_run);
    const testing = lib.testing;
    const Event = u32;

    return struct {
        const case_row = struct {
            name: []const u8,
            stack: usize,
            f: *const fn (Allocator) anyerror!void,
        };

        /// Per-case worker stacks; spawns live on `Thread` with default sizes—only the suite worker is tuned here.
        const case_rows: []const case_row = &.{
            .{ .name = "unbufferedInit", .stack = 96 * 1024, .f = testUnbufferedInit },
            .{ .name = "unbufferedRendezvous", .stack = 96 * 1024, .f = testUnbufferedRendezvous },
            .{ .name = "unbufferedSendBlocks", .stack = 96 * 1024, .f = testUnbufferedSendBlocks },
            .{ .name = "unbufferedRecvBlocks", .stack = 96 * 1024, .f = testUnbufferedRecvBlocks },
            .{ .name = "unbufferedMultiRound", .stack = 96 * 1024, .f = testUnbufferedMultiRound },
            .{ .name = "unbufferedCloseWakesRecv", .stack = 96 * 1024, .f = testUnbufferedCloseWakesRecv },
            .{ .name = "unbufferedCloseWakesSend", .stack = 96 * 1024, .f = testUnbufferedCloseWakesSend },
            .{ .name = "unbufferedSendAfterClose", .stack = 96 * 1024, .f = testUnbufferedSendAfterClose },
            .{ .name = "unbufferedRecvAfterClose", .stack = 96 * 1024, .f = testUnbufferedRecvAfterClose },
            .{ .name = "unbufferedSpsc", .stack = 128 * 1024, .f = testUnbufferedSpsc },
            .{ .name = "unbufferedMpsc", .stack = 128 * 1024, .f = testUnbufferedMpsc },
            .{ .name = "unbufferedDeinit", .stack = 96 * 1024, .f = testUnbufferedDeinit },
            .{ .name = "initBuffered", .stack = 96 * 1024, .f = testInitBuffered },
            .{ .name = "initialStateBuffered", .stack = 96 * 1024, .f = testInitialStateBuffered },
            .{ .name = "deinitClean", .stack = 96 * 1024, .f = testDeinitClean },
            .{ .name = "sendRecvSingle", .stack = 96 * 1024, .f = testSendRecvSingle },
            .{ .name = "fifoOrder", .stack = 96 * 1024, .f = testFifoOrder },
            .{ .name = "ringWrap", .stack = 96 * 1024, .f = testRingWrap },
            .{ .name = "sendRecvInterleaved", .stack = 96 * 1024, .f = testSendRecvInterleaved },
            .{ .name = "recvReturnsCorrectValue", .stack = 96 * 1024, .f = testRecvReturnsCorrectValue },
            .{ .name = "sendReturnsOk", .stack = 96 * 1024, .f = testSendReturnsOk },
            .{ .name = "bufferedSendImmediate", .stack = 96 * 1024, .f = testBufferedSendImmediate },
            .{ .name = "fillBufferExactly", .stack = 96 * 1024, .f = testFillBufferExactly },
            .{ .name = "capacityOne", .stack = 96 * 1024, .f = testCapacityOne },
            .{ .name = "ringWrapExtended", .stack = 96 * 1024, .f = testRingWrapExtended },
            .{ .name = "fillDrainTokenBalance", .stack = 96 * 1024, .f = testFillDrainTokenBalance },
            .{ .name = "multiRoundFillDrain", .stack = 96 * 1024, .f = testMultiRoundFillDrain },
            .{ .name = "closeSuccess", .stack = 96 * 1024, .f = testCloseSuccess },
            .{ .name = "sendAfterClose", .stack = 96 * 1024, .f = testSendAfterClose },
            .{ .name = "multiSendAfterClose", .stack = 96 * 1024, .f = testMultiSendAfterClose },
            .{ .name = "closeFlushBufferedData", .stack = 96 * 1024, .f = testCloseFlushBufferedData },
            .{ .name = "recvAfterCloseEmpty", .stack = 96 * 1024, .f = testRecvAfterCloseEmpty },
            .{ .name = "multiRecvAfterClose", .stack = 96 * 1024, .f = testMultiRecvAfterClose },
            .{ .name = "closeFlushFullFlow", .stack = 96 * 1024, .f = testCloseFlushFullFlow },
            .{ .name = "resourceSafetyNormal", .stack = 96 * 1024, .f = testResourceSafetyNormal },
            .{ .name = "resourceSafetyUnconsumed", .stack = 96 * 1024, .f = testResourceSafetyUnconsumed },
            .{ .name = "resourceSafetyCloseAndDeinit", .stack = 96 * 1024, .f = testResourceSafetyCloseAndDeinit },
            .{ .name = "sendBlocksWhenFull", .stack = 96 * 1024, .f = testSendBlocksWhenFull },
            .{ .name = "recvUnblocksSend", .stack = 96 * 1024, .f = testRecvUnblocksSend },
            .{ .name = "recvBlocksWhenEmpty", .stack = 96 * 1024, .f = testRecvBlocksWhenEmpty },
            .{ .name = "sendUnblocksRecv", .stack = 96 * 1024, .f = testSendUnblocksRecv },
            .{ .name = "recvWokenBySend", .stack = 96 * 1024, .f = testRecvWokenBySend },
            .{ .name = "sendWokenByRecv", .stack = 96 * 1024, .f = testSendWokenByRecv },
            .{ .name = "recvTimeoutContract", .stack = 96 * 1024, .f = testRecvTimeoutContract },
            .{ .name = "recvWokenByClose", .stack = 96 * 1024, .f = testRecvWokenByClose },
            .{ .name = "sendWokenByClose", .stack = 96 * 1024, .f = testSendWokenByClose },
            .{ .name = "closeWakesMultiRecv", .stack = 128 * 1024, .f = testCloseWakesMultiRecv },
            .{ .name = "closeWakesMultiSend", .stack = 128 * 1024, .f = testCloseWakesMultiSend },
            .{ .name = "highThroughputNoDeadlock", .stack = 128 * 1024, .f = testHighThroughputNoDeadlock },
            .{ .name = "spscNoDrop", .stack = 128 * 1024, .f = testSpscNoDrop },
            .{ .name = "mpscNoDrop", .stack = 128 * 1024, .f = testMpscNoDrop },
            .{ .name = "spmcNoDuplicate", .stack = 128 * 1024, .f = testSpmcNoDuplicate },
            .{ .name = "mpmcIntegrity", .stack = 128 * 1024, .f = testMpmcIntegrity },
            .{ .name = "concurrentCloseRecv", .stack = 128 * 1024, .f = testConcurrentCloseRecv },
            .{ .name = "concurrentCloseSend", .stack = 128 * 1024, .f = testConcurrentCloseSend },
            .{ .name = "rapidCloseRecv", .stack = 128 * 1024, .f = testRapidCloseRecv },
            .{ .name = "rapidCloseSend", .stack = 128 * 1024, .f = testRapidCloseSend },
            .{ .name = "bufferedRecvEmptyAfterDrain", .stack = 96 * 1024, .f = testBufferedRecvEmptyAfterDrain },
        };

        pub fn runUnderT(t: *testing_api.T, allocator: Allocator) bool {
            _ = allocator;
            t.parallel();
            inline for (case_rows) |row| {
                const stack = row.stack;
                const f = row.f;
                t.run(row.name, testing_api.TestRunner.fromFn(lib, stack, struct {
                    fn run(tt: *testing_api.T, a: Allocator) !void {
                        _ = tt;
                        try f(a);
                    }
                }.run));
            }
            return t.wait();
        }

        fn exec(allocator: Allocator) !void {
            var passed: u32 = 0;
            var failed: u32 = 0;
            inline for (case_rows) |row| {
                runOne(row.name, allocator, &passed, &failed, row.f);
            }
            if (failed > 0) return error.TestsFailed;
        }

        fn runOne(
            comptime name: []const u8,
            allocator: Allocator,
            passed: *u32,
            failed: *u32,
            comptime func: fn (Allocator) anyerror!void,
        ) void {
            const start = time.milliTimestamp();
            if (func(allocator)) |_| {
                passed.* += 1;
            } else |err| {
                const ms = time.milliTimestamp() - start;
                const elapsed_ms: u64 = if (ms <= 0) 0 else @intCast(ms);
                run_log.err("!!! [channel/{s}] {d}.{d:0>1}s, {d}ms: {s}", .{
                    name,
                    elapsed_ms / 1000,
                    (elapsed_ms % 1000) / 100,
                    elapsed_ms,
                    @errorName(err),
                });
                failed.* += 1;
            }
        }

        fn waitForTrue(flag: *Atomic(bool), timeout_ms: u64) !void {
            var elapsed_ms: u64 = 0;
            while (elapsed_ms < timeout_ms) : (elapsed_ms += 1) {
                if (flag.load(.acquire)) return;
                Thread.sleep(time.ns_per_ms);
            }
            return error.TimeoutWaitingForFlag;
        }

        fn waitForCount(flag: *Atomic(u32), expected: u32, timeout_ms: u64) !void {
            var elapsed_ms: u64 = 0;
            while (elapsed_ms < timeout_ms) : (elapsed_ms += 1) {
                if (flag.load(.acquire) >= expected) return;
                Thread.sleep(time.ns_per_ms);
            }
            return error.TimeoutWaitingForCount;
        }

        fn expectStaysFalse(flag: *Atomic(bool), duration_ms: u64) !void {
            var elapsed_ms: u64 = 0;
            while (elapsed_ms < duration_ms) : (elapsed_ms += 1) {
                if (flag.load(.acquire)) return error.FlagSetUnexpectedly;
                Thread.sleep(time.ns_per_ms);
            }
        }

        // ═══════════════════════════════════════════════════════════
        //  一、初始化与基本属性 (#1-#4)
        // ═══════════════════════════════════════════════════════════

        fn testInitBuffered(allocator: Allocator) !void {
            var ch1 = try Ch.make(allocator, 1);
            defer ch1.deinit();

            var ch64 = try Ch.make(allocator, 64);
            defer ch64.deinit();

            var ch1024 = try Ch.make(allocator, 1024);
            defer ch1024.deinit();
        }

        fn testInitialStateBuffered(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            _ = try ch.send(42);
            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 42), r.value);
        }

        fn testDeinitClean(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            _ = try ch.send(1);
            _ = try ch.send(2);
            ch.deinit();
        }

        // ═══════════════════════════════════════════════════════════
        //  二、发送与接收的基本语义 (#5-#10)
        // ═══════════════════════════════════════════════════════════

        fn testSendRecvSingle(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            const s = try ch.send(99);
            try testing.expect(s.ok);

            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 99), r.value);
        }

        fn testFifoOrder(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            defer ch.deinit();

            for (0..8) |i| {
                const s = try ch.send(@intCast(i));
                try testing.expect(s.ok);
            }

            for (0..8) |i| {
                const r = try ch.recv();
                try testing.expect(r.ok);
                try testing.expectEqual(@as(Event, @intCast(i)), r.value);
            }
        }

        fn testRingWrap(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            for (0..10) |i| {
                const s = try ch.send(@intCast(i));
                try testing.expect(s.ok);
                const r = try ch.recv();
                try testing.expect(r.ok);
                try testing.expectEqual(@as(Event, @intCast(i)), r.value);
            }
        }

        fn testSendRecvInterleaved(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            _ = try ch.send(10);
            _ = try ch.send(20);

            const r1 = try ch.recv();
            try testing.expect(r1.ok);
            try testing.expectEqual(@as(Event, 10), r1.value);

            _ = try ch.send(30);

            const r2 = try ch.recv();
            try testing.expect(r2.ok);
            try testing.expectEqual(@as(Event, 20), r2.value);

            const r3 = try ch.recv();
            try testing.expect(r3.ok);
            try testing.expectEqual(@as(Event, 30), r3.value);
        }

        fn testRecvReturnsCorrectValue(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            _ = try ch.send(0xAB);
            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 0xAB), r.value);
        }

        fn testSendReturnsOk(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            const s = try ch.send(1);
            try testing.expect(s.ok);

            const r = try ch.recv();
            try testing.expect(r.ok);
        }

        // ═══════════════════════════════════════════════════════════
        //  三、有缓冲 channel 缓冲区边界 (#11-#20)
        // ═══════════════════════════════════════════════════════════

        fn testBufferedSendImmediate(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            defer ch.deinit();

            const s = try ch.send(1);
            try testing.expect(s.ok);
        }

        fn testFillBufferExactly(allocator: Allocator) !void {
            const cap = 8;
            var ch = try Ch.make(allocator, cap);
            defer ch.deinit();

            for (0..cap) |i| {
                const s = try ch.send(@intCast(i));
                try testing.expect(s.ok);
            }
        }

        fn testSendBlocksWhenFull(allocator: Allocator) !void {
            const cap = 4;
            var ch = try Ch.make(allocator, cap);
            defer ch.deinit();

            for (0..cap) |i| {
                _ = try ch.send(@intCast(i));
            }

            var entered = Atomic(bool).init(false);
            var finished = Atomic(bool).init(false);
            const t = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *Atomic(bool), fin: *Atomic(bool)) void {
                    ent.store(true, .release);
                    _ = c.send(0xFF) catch {};
                    fin.store(true, .release);
                }
            }.run, .{ &ch, &entered, &finished });

            try waitForTrue(&entered, 200);
            try expectStaysFalse(&finished, 50);

            _ = try ch.recv();
            t.join();
            try testing.expect(finished.load(.acquire));
        }

        fn testRecvUnblocksSend(allocator: Allocator) !void {
            const cap = 2;
            var ch = try Ch.make(allocator, cap);
            defer ch.deinit();

            _ = try ch.send(1);
            _ = try ch.send(2);

            var entered = Atomic(bool).init(false);
            var send_ok = Atomic(bool).init(false);
            const t = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *Atomic(bool), flag: *Atomic(bool)) void {
                    ent.store(true, .release);
                    const s = c.send(3) catch return;
                    flag.store(s.ok, .release);
                }
            }.run, .{ &ch, &entered, &send_ok });

            try waitForTrue(&entered, 200);

            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 1), r.value);

            t.join();
            try testing.expect(send_ok.load(.acquire));

            const r2 = try ch.recv();
            try testing.expect(r2.ok);
            try testing.expectEqual(@as(Event, 2), r2.value);

            const r3 = try ch.recv();
            try testing.expect(r3.ok);
            try testing.expectEqual(@as(Event, 3), r3.value);
        }

        fn testRecvBlocksWhenEmpty(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            var entered = Atomic(bool).init(false);
            var finished = Atomic(bool).init(false);
            const t = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *Atomic(bool), fin: *Atomic(bool)) void {
                    ent.store(true, .release);
                    _ = c.recv() catch {};
                    fin.store(true, .release);
                }
            }.run, .{ &ch, &entered, &finished });

            try waitForTrue(&entered, 200);
            try expectStaysFalse(&finished, 50);

            _ = try ch.send(42);
            t.join();
            try testing.expect(finished.load(.acquire));
        }

        fn testSendUnblocksRecv(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            var entered = Atomic(bool).init(false);
            var recv_ok = Atomic(bool).init(false);
            var recv_val = Atomic(Event).init(0);
            const t = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *Atomic(bool), ok_flag: *Atomic(bool), val_flag: *Atomic(Event)) void {
                    ent.store(true, .release);
                    const r = c.recv() catch return;
                    if (r.ok) {
                        val_flag.store(r.value, .release);
                        ok_flag.store(true, .release);
                    }
                }
            }.run, .{ &ch, &entered, &recv_ok, &recv_val });

            try waitForTrue(&entered, 200);
            _ = try ch.send(0xBEEF);
            t.join();

            try testing.expect(recv_ok.load(.acquire));
            try testing.expectEqual(@as(Event, 0xBEEF), recv_val.load(.acquire));
        }

        fn testCapacityOne(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 1);
            defer ch.deinit();

            const s = try ch.send(10);
            try testing.expect(s.ok);

            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 10), r.value);

            _ = try ch.send(30);
            const r2 = try ch.recv();
            try testing.expect(r2.ok);
            try testing.expectEqual(@as(Event, 30), r2.value);
        }

        fn testRingWrapExtended(allocator: Allocator) !void {
            const cap = 4;
            var ch = try Ch.make(allocator, cap);
            defer ch.deinit();

            for (0..cap * 3) |i| {
                _ = try ch.send(@intCast(i));
                const r = try ch.recv();
                try testing.expect(r.ok);
                try testing.expectEqual(@as(Event, @intCast(i)), r.value);
            }
        }

        fn testFillDrainTokenBalance(allocator: Allocator) !void {
            const cap = 8;
            var ch = try Ch.make(allocator, cap);
            defer ch.deinit();

            for (0..cap) |i| {
                _ = try ch.send(@intCast(i));
            }
            for (0..cap) |_| {
                const r = try ch.recv();
                try testing.expect(r.ok);
            }

            for (0..cap) |i| {
                _ = try ch.send(@intCast(i));
            }
            for (0..cap) |_| {
                const r = try ch.recv();
                try testing.expect(r.ok);
            }
        }

        fn testMultiRoundFillDrain(allocator: Allocator) !void {
            const cap = 4;
            var ch = try Ch.make(allocator, cap);
            defer ch.deinit();

            for (0..5) |round| {
                for (0..cap) |i| {
                    const val: Event = @intCast(round * cap + i);
                    _ = try ch.send(val);
                }
                for (0..cap) |i| {
                    const r = try ch.recv();
                    try testing.expect(r.ok);
                    const expected: Event = @intCast(round * cap + i);
                    try testing.expectEqual(expected, r.value);
                }
            }
        }

        // ═══════════════════════════════════════════════════════════
        //  四、close 的 Go 语义 (#21-#27)
        // ═══════════════════════════════════════════════════════════

        fn testCloseSuccess(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();
            ch.close();
        }

        fn testSendAfterClose(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();
            ch.close();

            const s = try ch.send(1);
            try testing.expect(!s.ok);
        }

        fn testMultiSendAfterClose(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();
            ch.close();

            for (0..5) |i| {
                const s = try ch.send(@intCast(i));
                try testing.expect(!s.ok);
            }
        }

        fn testCloseFlushBufferedData(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            defer ch.deinit();

            _ = try ch.send(10);
            _ = try ch.send(20);
            _ = try ch.send(30);
            ch.close();

            const r1 = try ch.recv();
            try testing.expect(r1.ok);
            try testing.expectEqual(@as(Event, 10), r1.value);

            const r2 = try ch.recv();
            try testing.expect(r2.ok);
            try testing.expectEqual(@as(Event, 20), r2.value);

            const r3 = try ch.recv();
            try testing.expect(r3.ok);
            try testing.expectEqual(@as(Event, 30), r3.value);
        }

        fn testRecvAfterCloseEmpty(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();
            ch.close();

            const r = try ch.recv();
            try testing.expect(!r.ok);
        }

        fn testMultiRecvAfterClose(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();
            ch.close();

            for (0..5) |_| {
                const r = try ch.recv();
                try testing.expect(!r.ok);
            }
        }

        fn testCloseFlushFullFlow(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            defer ch.deinit();

            for (0..5) |i| {
                _ = try ch.send(@intCast(i));
            }
            ch.close();

            for (0..5) |i| {
                const r = try ch.recv();
                try testing.expect(r.ok);
                try testing.expectEqual(@as(Event, @intCast(i)), r.value);
            }

            const r_end = try ch.recv();
            try testing.expect(!r_end.ok);
        }

        // ═══════════════════════════════════════════════════════════
        //  五、阻塞路径与唤醒 (#28-#34)
        // ═══════════════════════════════════════════════════════════

        fn testRecvWokenBySend(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            var entered = Atomic(bool).init(false);
            var recv_ok = Atomic(bool).init(false);
            var recv_val = Atomic(Event).init(0);
            const t = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *Atomic(bool), ok_flag: *Atomic(bool), val_flag: *Atomic(Event)) void {
                    ent.store(true, .release);
                    const r = c.recv() catch return;
                    if (r.ok) {
                        val_flag.store(r.value, .release);
                        ok_flag.store(true, .release);
                    }
                }
            }.run, .{ &ch, &entered, &recv_ok, &recv_val });

            try waitForTrue(&entered, 200);
            _ = try ch.send(0xCAFE);
            t.join();

            try testing.expect(recv_ok.load(.acquire));
            try testing.expectEqual(@as(Event, 0xCAFE), recv_val.load(.acquire));
        }

        fn testSendWokenByRecv(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 2);
            defer ch.deinit();

            _ = try ch.send(1);
            _ = try ch.send(2);

            var entered = Atomic(bool).init(false);
            var send_ok = Atomic(bool).init(false);
            const t = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *Atomic(bool), flag: *Atomic(bool)) void {
                    ent.store(true, .release);
                    const s = c.send(3) catch return;
                    flag.store(s.ok, .release);
                }
            }.run, .{ &ch, &entered, &send_ok });

            try waitForTrue(&entered, 200);
            _ = try ch.recv();
            t.join();

            try testing.expect(send_ok.load(.acquire));
        }

        fn testRecvTimeoutContract(allocator: Allocator) !void {
            const cases = [_]usize{ 0, 1 };

            for (cases) |capacity| {
                var ch = try Ch.make(allocator, capacity);
                defer ch.deinit();

                try testing.expectError(error.Timeout, ch.recvTimeout(5));

                const sender = try Thread.spawn(.{}, struct {
                    fn run(c: *Ch) void {
                        Thread.sleep(time.ns_per_ms);
                        _ = c.send(0xD00D) catch {};
                    }
                }.run, .{&ch});

                const r = try ch.recvTimeout(200);
                try testing.expect(r.ok);
                try testing.expectEqual(@as(Event, 0xD00D), r.value);
                sender.join();

                ch.close();
                const closed = try ch.recvTimeout(5);
                try testing.expect(!closed.ok);
            }
        }

        fn testRecvWokenByClose(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            var entered = Atomic(bool).init(false);
            var recv_ok = Atomic(bool).init(true);
            const t = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *Atomic(bool), flag: *Atomic(bool)) void {
                    ent.store(true, .release);
                    const r = c.recv() catch {
                        flag.store(false, .release);
                        return;
                    };
                    flag.store(r.ok, .release);
                }
            }.run, .{ &ch, &entered, &recv_ok });

            try waitForTrue(&entered, 200);
            ch.close();
            t.join();

            try testing.expect(!recv_ok.load(.acquire));
        }

        fn testSendWokenByClose(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 2);
            defer ch.deinit();

            _ = try ch.send(1);
            _ = try ch.send(2);

            var entered = Atomic(bool).init(false);
            var send_ok = Atomic(bool).init(true);
            const t = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *Atomic(bool), flag: *Atomic(bool)) void {
                    ent.store(true, .release);
                    const s = c.send(99) catch {
                        flag.store(false, .release);
                        return;
                    };
                    flag.store(s.ok, .release);
                }
            }.run, .{ &ch, &entered, &send_ok });

            try waitForTrue(&entered, 200);
            ch.close();
            t.join();

            try testing.expect(!send_ok.load(.acquire));
        }

        fn testCloseWakesMultiRecv(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            const N = 4;
            var started = Atomic(u32).init(0);
            var done_count = Atomic(u32).init(0);
            var threads: [N]Thread = undefined;

            for (0..N) |i| {
                threads[i] = try Thread.spawn(.{}, struct {
                    fn run(c: *Ch, started_count: *Atomic(u32), cnt: *Atomic(u32)) void {
                        _ = started_count.fetchAdd(1, .acq_rel);
                        const r = c.recv() catch {
                            _ = cnt.fetchAdd(1, .acq_rel);
                            return;
                        };
                        if (!r.ok) {
                            _ = cnt.fetchAdd(1, .acq_rel);
                        }
                    }
                }.run, .{ &ch, &started, &done_count });
            }

            try waitForCount(&started, @as(u32, N), 200);
            ch.close();

            for (0..N) |i| {
                threads[i].join();
            }

            try testing.expectEqual(@as(u32, N), done_count.load(.acquire));
        }

        fn testCloseWakesMultiSend(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 2);
            defer ch.deinit();

            _ = try ch.send(1);
            _ = try ch.send(2);

            const N = 4;
            var started = Atomic(u32).init(0);
            var done_count = Atomic(u32).init(0);
            var threads: [N]Thread = undefined;

            for (0..N) |i| {
                threads[i] = try Thread.spawn(.{}, struct {
                    fn run(c: *Ch, started_count: *Atomic(u32), cnt: *Atomic(u32)) void {
                        _ = started_count.fetchAdd(1, .acq_rel);
                        const s = c.send(99) catch {
                            _ = cnt.fetchAdd(1, .acq_rel);
                            return;
                        };
                        if (!s.ok) {
                            _ = cnt.fetchAdd(1, .acq_rel);
                        }
                    }
                }.run, .{ &ch, &started, &done_count });
            }

            try waitForCount(&started, @as(u32, N), 200);
            ch.close();

            for (0..N) |i| {
                threads[i].join();
            }

            try testing.expectEqual(@as(u32, N), done_count.load(.acquire));
        }

        fn testHighThroughputNoDeadlock(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 64);
            defer ch.deinit();

            const COUNT = 10_000;

            const sender = try Thread.spawn(.{}, struct {
                fn run(c: *Ch) void {
                    for (0..COUNT) |i| {
                        _ = c.send(@intCast(i)) catch return;
                    }
                }
            }.run, .{&ch});

            var received: u32 = 0;
            for (0..COUNT) |_| {
                const r = try ch.recv();
                if (r.ok) received += 1;
            }

            sender.join();
            try testing.expectEqual(@as(u32, COUNT), received);
        }

        // ═══════════════════════════════════════════════════════════
        //  六、并发正确性 (#35-#41)
        // ═══════════════════════════════════════════════════════════

        fn testSpscNoDrop(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 32);
            defer ch.deinit();

            const N = 1000;

            const sender = try Thread.spawn(.{}, struct {
                fn run(c: *Ch) void {
                    for (0..N) |i| {
                        _ = c.send(@intCast(i)) catch return;
                    }
                }
            }.run, .{&ch});

            var count: u32 = 0;
            while (count < N) {
                const r = try ch.recv();
                if (r.ok) {
                    try testing.expectEqual(@as(Event, @intCast(count)), r.value);
                    count += 1;
                }
            }

            sender.join();
        }

        fn testMpscNoDrop(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 32);
            defer ch.deinit();

            const PRODUCERS = 4;
            const PER_PRODUCER = 250;
            const TOTAL = PRODUCERS * PER_PRODUCER;

            var threads: [PRODUCERS]Thread = undefined;
            for (0..PRODUCERS) |p| {
                threads[p] = try Thread.spawn(.{}, struct {
                    fn run(c: *Ch, base: u32) void {
                        for (0..PER_PRODUCER) |i| {
                            _ = c.send(@intCast(base + @as(u32, @intCast(i)))) catch return;
                        }
                    }
                }.run, .{ &ch, @as(u32, @intCast(p * PER_PRODUCER)) });
            }

            var seen = [_]bool{false} ** TOTAL;
            var count: u32 = 0;
            while (count < TOTAL) {
                const r = try ch.recv();
                if (r.ok) {
                    const idx: usize = @intCast(r.value);
                    try testing.expect(!seen[idx]);
                    seen[idx] = true;
                    count += 1;
                }
            }

            for (0..PRODUCERS) |p| {
                threads[p].join();
            }

            for (seen) |s| {
                try testing.expect(s);
            }
        }

        fn testSpmcNoDuplicate(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 32);
            defer ch.deinit();

            const CONSUMERS = 4;
            const TOTAL = 1000;
            const Observed = struct {
                mutex: Thread.Mutex = .{},
                count: u32 = 0,
                duplicate: bool = false,
                out_of_range: bool = false,
                seen: [TOTAL]bool = [_]bool{false} ** TOTAL,

                fn record(self: *@This(), value: Event) void {
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    const idx: usize = @intCast(value);
                    if (idx >= TOTAL) {
                        self.out_of_range = true;
                        return;
                    }
                    if (self.seen[idx]) {
                        self.duplicate = true;
                        return;
                    }
                    self.seen[idx] = true;
                    self.count += 1;
                }
            };

            var sender_failed = Atomic(bool).init(false);
            const sender = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, failed: *Atomic(bool)) void {
                    for (0..TOTAL) |i| {
                        const s = c.send(@intCast(i)) catch {
                            failed.store(true, .release);
                            return;
                        };
                        if (!s.ok) {
                            failed.store(true, .release);
                            return;
                        }
                    }
                    c.close();
                }
            }.run, .{ &ch, &sender_failed });

            var observed = Observed{};
            var consumers: [CONSUMERS]Thread = undefined;
            for (0..CONSUMERS) |c| {
                consumers[c] = try Thread.spawn(.{}, struct {
                    fn run(channel: *Ch, obs: *Observed) void {
                        while (true) {
                            const r = channel.recv() catch return;
                            if (!r.ok) break;
                            obs.record(r.value);
                        }
                    }
                }.run, .{ &ch, &observed });
            }

            sender.join();
            for (0..CONSUMERS) |c| {
                consumers[c].join();
            }

            try testing.expect(!sender_failed.load(.acquire));
            try testing.expect(!observed.out_of_range);
            try testing.expect(!observed.duplicate);
            try testing.expectEqual(@as(u32, TOTAL), observed.count);
            for (observed.seen) |seen| {
                try testing.expect(seen);
            }
        }

        fn testMpmcIntegrity(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 64);
            defer ch.deinit();

            const PRODUCERS = 4;
            const CONSUMERS = 4;
            const PER_PRODUCER = 500;
            const TOTAL = PRODUCERS * PER_PRODUCER;
            const Observed = struct {
                mutex: Thread.Mutex = .{},
                count: u32 = 0,
                duplicate: bool = false,
                out_of_range: bool = false,
                seen: [TOTAL]bool = [_]bool{false} ** TOTAL,

                fn record(self: *@This(), value: Event) void {
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    const idx: usize = @intCast(value);
                    if (idx >= TOTAL) {
                        self.out_of_range = true;
                        return;
                    }
                    if (self.seen[idx]) {
                        self.duplicate = true;
                        return;
                    }
                    self.seen[idx] = true;
                    self.count += 1;
                }
            };

            var producer_failed = Atomic(bool).init(false);
            var observed = Observed{};

            var cons_threads: [CONSUMERS]Thread = undefined;
            for (0..CONSUMERS) |c| {
                cons_threads[c] = try Thread.spawn(.{}, struct {
                    fn run(channel: *Ch, obs: *Observed) void {
                        while (true) {
                            const r = channel.recv() catch return;
                            if (!r.ok) return;
                            obs.record(r.value);
                        }
                    }
                }.run, .{ &ch, &observed });
            }

            var prod_threads: [PRODUCERS]Thread = undefined;
            for (0..PRODUCERS) |p| {
                prod_threads[p] = try Thread.spawn(.{}, struct {
                    fn run(c: *Ch, base: u32, failed: *Atomic(bool)) void {
                        for (0..PER_PRODUCER) |i| {
                            const s = c.send(@intCast(base + @as(u32, @intCast(i)))) catch {
                                failed.store(true, .release);
                                return;
                            };
                            if (!s.ok) {
                                failed.store(true, .release);
                                return;
                            }
                        }
                    }
                }.run, .{ &ch, @as(u32, @intCast(p * PER_PRODUCER)), &producer_failed });
            }

            for (0..PRODUCERS) |p| {
                prod_threads[p].join();
            }

            ch.close();

            for (0..CONSUMERS) |c| {
                cons_threads[c].join();
            }

            try testing.expect(!producer_failed.load(.acquire));
            try testing.expect(!observed.out_of_range);
            try testing.expect(!observed.duplicate);
            try testing.expectEqual(@as(u32, TOTAL), observed.count);
            for (observed.seen) |seen| {
                try testing.expect(seen);
            }
        }

        fn testConcurrentCloseRecv(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            defer ch.deinit();

            _ = try ch.send(10);
            _ = try ch.send(20);
            _ = try ch.send(30);

            var started = Atomic(u32).init(0);
            var recv_count = Atomic(u32).init(0);
            const N = 4;
            var threads: [N]Thread = undefined;

            for (0..N) |i| {
                threads[i] = try Thread.spawn(.{}, struct {
                    fn run(c: *Ch, started_count: *Atomic(u32), cnt: *Atomic(u32)) void {
                        _ = started_count.fetchAdd(1, .acq_rel);
                        while (true) {
                            const r = c.recv() catch return;
                            if (!r.ok) return;
                            _ = cnt.fetchAdd(1, .acq_rel);
                        }
                    }
                }.run, .{ &ch, &started, &recv_count });
            }

            try waitForCount(&started, @as(u32, N), 200);
            ch.close();

            for (0..N) |i| {
                threads[i].join();
            }

            try testing.expectEqual(@as(u32, 3), recv_count.load(.acquire));
        }

        fn testConcurrentCloseSend(allocator: Allocator) !void {
            const cap = 4;
            const N = 8;
            var ch = try Ch.make(allocator, cap);
            defer ch.deinit();

            var started = Atomic(u32).init(0);
            var send_success: [N]Atomic(bool) = undefined;
            for (&send_success) |*flag| {
                flag.* = Atomic(bool).init(false);
            }
            var send_ok_count = Atomic(u32).init(0);
            var send_fail_count = Atomic(u32).init(0);
            var threads: [N]Thread = undefined;

            for (0..N) |i| {
                threads[i] = try Thread.spawn(.{}, struct {
                    fn run(c: *Ch, started_count: *Atomic(u32), value: Event, success_flag: *Atomic(bool), ok_cnt: *Atomic(u32), fail_cnt: *Atomic(u32)) void {
                        _ = started_count.fetchAdd(1, .acq_rel);
                        const s = c.send(value) catch {
                            _ = fail_cnt.fetchAdd(1, .acq_rel);
                            return;
                        };
                        if (s.ok) {
                            success_flag.store(true, .release);
                            _ = ok_cnt.fetchAdd(1, .acq_rel);
                        } else {
                            _ = fail_cnt.fetchAdd(1, .acq_rel);
                        }
                    }
                }.run, .{ &ch, &started, @as(Event, @intCast(i)), &send_success[i], &send_ok_count, &send_fail_count });
            }

            try waitForCount(&started, @as(u32, N), 200);
            ch.close();

            for (0..N) |i| {
                threads[i].join();
            }

            const ok = send_ok_count.load(.acquire);
            const fail = send_fail_count.load(.acquire);
            try testing.expectEqual(@as(u32, N), ok + fail);

            try testing.expect(ok <= @as(u32, cap));

            var drained_seen = [_]bool{false} ** N;
            var drained_count: u32 = 0;
            while (true) {
                const r = try ch.recv();
                if (!r.ok) break;

                const idx: usize = @intCast(r.value);
                if (idx >= N) return error.ValueOutOfRange;
                try testing.expect(!drained_seen[idx]);
                drained_seen[idx] = true;
                try testing.expect(send_success[idx].load(.acquire));
                drained_count += 1;
            }

            try testing.expectEqual(ok, drained_count);
            for (0..N) |i| {
                try testing.expectEqual(send_success[i].load(.acquire), drained_seen[i]);
            }
        }

        // ═══════════════════════════════════════════════════════════
        //  七、资源安全 (#42-#46)
        // ═══════════════════════════════════════════════════════════

        fn testResourceSafetyNormal(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            _ = try ch.send(1);
            _ = try ch.send(2);
            _ = try ch.recv();
            _ = try ch.recv();
            ch.deinit();
        }

        fn testResourceSafetyUnconsumed(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            _ = try ch.send(1);
            _ = try ch.send(2);
            _ = try ch.send(3);
            ch.deinit();
        }

        fn testResourceSafetyCloseAndDeinit(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            _ = try ch.send(1);
            ch.close();
            ch.deinit();
        }

        fn testRapidCloseRecv(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            ch.close();
            for (0..10) |_| {
                const r = try ch.recv();
                try testing.expect(!r.ok);
            }
        }

        fn testRapidCloseSend(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            ch.close();
            for (0..10) |_| {
                const s = try ch.send(1);
                try testing.expect(!s.ok);
            }
        }

        /// Buffered channel: send fewer items than receivers, then close.
        /// Receivers that drain real data get ok=true; the rest hit len==0
        /// and must return ok=false without deadlocking. This exercises the
        /// recvBuffered path where the wakeup token is consumed but the
        /// ring buffer is already empty.
        fn testBufferedRecvEmptyAfterDrain(allocator: Allocator) !void {
            const ITEMS = 3;
            const RECEIVERS = 8;
            var ch = try Ch.make(allocator, ITEMS);
            defer ch.deinit();

            for (0..ITEMS) |i| {
                _ = try ch.send(@intCast(i));
            }

            var started = Atomic(u32).init(0);
            var ok_count = Atomic(u32).init(0);
            var fail_count = Atomic(u32).init(0);
            var threads: [RECEIVERS]Thread = undefined;

            for (0..RECEIVERS) |i| {
                threads[i] = try Thread.spawn(.{}, struct {
                    fn run(c: *Ch, started_count: *Atomic(u32), ok_cnt: *Atomic(u32), fail_cnt: *Atomic(u32)) void {
                        _ = started_count.fetchAdd(1, .acq_rel);
                        const r = c.recv() catch {
                            _ = fail_cnt.fetchAdd(1, .acq_rel);
                            return;
                        };
                        if (r.ok) {
                            _ = ok_cnt.fetchAdd(1, .acq_rel);
                        } else {
                            _ = fail_cnt.fetchAdd(1, .acq_rel);
                        }
                    }
                }.run, .{ &ch, &started, &ok_count, &fail_count });
            }

            try waitForCount(&started, @as(u32, RECEIVERS), 200);
            ch.close();

            for (0..RECEIVERS) |i| {
                threads[i].join();
            }

            const ok = ok_count.load(.acquire);
            const fail = fail_count.load(.acquire);
            try testing.expectEqual(@as(u32, RECEIVERS), ok + fail);
            try testing.expectEqual(@as(u32, ITEMS), ok);
        }

        // ═══════════════════════════════════════════════════════════
        //  〇、无缓冲 channel (U1-U12)
        // ═══════════════════════════════════════════════════════════

        fn testUnbufferedInit(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();
        }

        fn testUnbufferedRendezvous(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();

            var entered = Atomic(bool).init(false);
            var recv_val = Atomic(Event).init(0);
            var recv_ok = Atomic(bool).init(false);
            const t = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *Atomic(bool), val: *Atomic(Event), ok: *Atomic(bool)) void {
                    ent.store(true, .release);
                    const r = c.recv() catch return;
                    if (r.ok) {
                        val.store(r.value, .release);
                        ok.store(true, .release);
                    }
                }
            }.run, .{ &ch, &entered, &recv_val, &recv_ok });

            try waitForTrue(&entered, 200);
            const s = try ch.send(0xDEAD);
            try testing.expect(s.ok);
            t.join();

            try testing.expect(recv_ok.load(.acquire));
            try testing.expectEqual(@as(Event, 0xDEAD), recv_val.load(.acquire));
        }

        fn testUnbufferedSendBlocks(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();

            var entered = Atomic(bool).init(false);
            var finished = Atomic(bool).init(false);
            const t = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *Atomic(bool), fin: *Atomic(bool)) void {
                    ent.store(true, .release);
                    _ = c.send(1) catch {};
                    fin.store(true, .release);
                }
            }.run, .{ &ch, &entered, &finished });

            try waitForTrue(&entered, 200);
            try expectStaysFalse(&finished, 50);

            _ = try ch.recv();
            t.join();
            try testing.expect(finished.load(.acquire));
        }

        fn testUnbufferedRecvBlocks(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();

            var entered = Atomic(bool).init(false);
            var finished = Atomic(bool).init(false);
            const t = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *Atomic(bool), fin: *Atomic(bool)) void {
                    ent.store(true, .release);
                    _ = c.recv() catch {};
                    fin.store(true, .release);
                }
            }.run, .{ &ch, &entered, &finished });

            try waitForTrue(&entered, 200);
            try expectStaysFalse(&finished, 50);

            _ = try ch.send(42);
            t.join();
            try testing.expect(finished.load(.acquire));
        }

        fn testUnbufferedMultiRound(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();

            const N = 100;
            const receiver = try Thread.spawn(.{}, struct {
                fn run(c: *Ch) !void {
                    for (0..N) |i| {
                        const r = try c.recv();
                        try testing.expect(r.ok);
                        try testing.expectEqual(@as(Event, @intCast(i)), r.value);
                    }
                }
            }.run, .{&ch});

            for (0..N) |i| {
                const s = try ch.send(@intCast(i));
                try testing.expect(s.ok);
            }
            receiver.join();
        }

        fn testUnbufferedCloseWakesRecv(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();

            var entered = Atomic(bool).init(false);
            var recv_ok = Atomic(bool).init(true);
            const t = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *Atomic(bool), flag: *Atomic(bool)) void {
                    ent.store(true, .release);
                    const r = c.recv() catch {
                        flag.store(false, .release);
                        return;
                    };
                    flag.store(r.ok, .release);
                }
            }.run, .{ &ch, &entered, &recv_ok });

            try waitForTrue(&entered, 200);
            ch.close();
            t.join();

            try testing.expect(!recv_ok.load(.acquire));
        }

        fn testUnbufferedCloseWakesSend(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();

            var entered = Atomic(bool).init(false);
            var send_ok = Atomic(bool).init(true);
            const t = try Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *Atomic(bool), flag: *Atomic(bool)) void {
                    ent.store(true, .release);
                    const s = c.send(99) catch {
                        flag.store(false, .release);
                        return;
                    };
                    flag.store(s.ok, .release);
                }
            }.run, .{ &ch, &entered, &send_ok });

            try waitForTrue(&entered, 200);
            ch.close();
            t.join();

            try testing.expect(!send_ok.load(.acquire));
        }

        fn testUnbufferedSendAfterClose(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();
            ch.close();

            const s = try ch.send(1);
            try testing.expect(!s.ok);
        }

        fn testUnbufferedRecvAfterClose(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();
            ch.close();

            const r = try ch.recv();
            try testing.expect(!r.ok);
        }

        fn testUnbufferedSpsc(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();

            const N = 500;
            const sender = try Thread.spawn(.{}, struct {
                fn run(c: *Ch) void {
                    for (0..N) |i| {
                        _ = c.send(@intCast(i)) catch return;
                    }
                }
            }.run, .{&ch});

            var count: u32 = 0;
            while (count < N) {
                const r = try ch.recv();
                if (r.ok) {
                    try testing.expectEqual(@as(Event, @intCast(count)), r.value);
                    count += 1;
                }
            }
            sender.join();
        }

        fn testUnbufferedMpsc(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();

            const PRODUCERS = 4;
            const PER_PRODUCER = 100;
            const TOTAL = PRODUCERS * PER_PRODUCER;

            var threads: [PRODUCERS]Thread = undefined;
            for (0..PRODUCERS) |p| {
                threads[p] = try Thread.spawn(.{}, struct {
                    fn run(c: *Ch, base: u32) void {
                        for (0..PER_PRODUCER) |i| {
                            _ = c.send(@intCast(base + @as(u32, @intCast(i)))) catch return;
                        }
                    }
                }.run, .{ &ch, @as(u32, @intCast(p * PER_PRODUCER)) });
            }

            var seen = [_]bool{false} ** TOTAL;
            var count: u32 = 0;
            while (count < TOTAL) {
                const r = try ch.recv();
                if (r.ok) {
                    const idx: usize = @intCast(r.value);
                    try testing.expect(!seen[idx]);
                    seen[idx] = true;
                    count += 1;
                }
            }

            for (0..PRODUCERS) |p| {
                threads[p].join();
            }
            for (seen) |s| {
                try testing.expect(s);
            }
        }

        fn testUnbufferedDeinit(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            ch.deinit();

            var ch2 = try Ch.make(allocator, 0);
            ch2.close();
            ch2.deinit();
        }
    };
}
