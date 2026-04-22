//! Shared Channel contract integration suite (per-case runners invoke methods here).

pub fn Suite(comptime lib: type, comptime Channel: fn (type) type) type {
    const Ch = Channel(u32);
    const Thread = lib.Thread;
    const Allocator = lib.mem.Allocator;
    const Atomic = lib.atomic.Value;
    const time = lib.time;
    const testing = lib.testing;
    const Event = u32;

    return struct {
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

        pub fn testInitBuffered(allocator: Allocator) !void {
            var ch1 = try Ch.make(allocator, 1);
            defer ch1.deinit();

            var ch64 = try Ch.make(allocator, 64);
            defer ch64.deinit();

            var ch1024 = try Ch.make(allocator, 1024);
            defer ch1024.deinit();
        }

        pub fn testInitialStateBuffered(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            _ = try ch.send(42);
            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 42), r.value);
        }

        pub fn testDeinitClean(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            _ = try ch.send(1);
            _ = try ch.send(2);
            ch.deinit();
        }

        // ═══════════════════════════════════════════════════════════
        //  二、发送与接收的基本语义 (#5-#10)
        // ═══════════════════════════════════════════════════════════

        pub fn testSendRecvSingle(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            const s = try ch.send(99);
            try testing.expect(s.ok);

            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 99), r.value);
        }

        pub fn testFifoOrder(allocator: Allocator) !void {
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

        pub fn testRingWrap(allocator: Allocator) !void {
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

        pub fn testSendRecvInterleaved(allocator: Allocator) !void {
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

        pub fn testRecvReturnsCorrectValue(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            _ = try ch.send(0xAB);
            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 0xAB), r.value);
        }

        pub fn testSendReturnsOk(allocator: Allocator) !void {
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

        pub fn testBufferedSendImmediate(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            defer ch.deinit();

            const s = try ch.send(1);
            try testing.expect(s.ok);
        }

        pub fn testFillBufferExactly(allocator: Allocator) !void {
            const cap = 8;
            var ch = try Ch.make(allocator, cap);
            defer ch.deinit();

            for (0..cap) |i| {
                const s = try ch.send(@intCast(i));
                try testing.expect(s.ok);
            }
        }

        pub fn testSendBlocksWhenFull(allocator: Allocator) !void {
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

        pub fn testRecvUnblocksSend(allocator: Allocator) !void {
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

        pub fn testRecvBlocksWhenEmpty(allocator: Allocator) !void {
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

        pub fn testSendUnblocksRecv(allocator: Allocator) !void {
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

        pub fn testCapacityOne(allocator: Allocator) !void {
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

        pub fn testRingWrapExtended(allocator: Allocator) !void {
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

        pub fn testFillDrainTokenBalance(allocator: Allocator) !void {
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

        pub fn testMultiRoundFillDrain(allocator: Allocator) !void {
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

        pub fn testCloseSuccess(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();
            ch.close();
        }

        pub fn testSendAfterClose(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();
            ch.close();

            const s = try ch.send(1);
            try testing.expect(!s.ok);
        }

        pub fn testMultiSendAfterClose(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();
            ch.close();

            for (0..5) |i| {
                const s = try ch.send(@intCast(i));
                try testing.expect(!s.ok);
            }
        }

        pub fn testCloseFlushBufferedData(allocator: Allocator) !void {
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

        pub fn testRecvAfterCloseEmpty(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();
            ch.close();

            const r = try ch.recv();
            try testing.expect(!r.ok);
        }

        pub fn testMultiRecvAfterClose(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();
            ch.close();

            for (0..5) |_| {
                const r = try ch.recv();
                try testing.expect(!r.ok);
            }
        }

        pub fn testCloseFlushFullFlow(allocator: Allocator) !void {
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

        pub fn testRecvWokenBySend(allocator: Allocator) !void {
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

        pub fn testSendWokenByRecv(allocator: Allocator) !void {
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

        pub fn testSendTimeoutContract(allocator: Allocator) !void {
            {
                var ch = try Ch.make(allocator, 0);
                defer ch.deinit();

                try testing.expectError(error.Timeout, ch.sendTimeout(0xD00D, 5));
                try testing.expectError(error.Timeout, ch.recvTimeout(5));

                var recv_ok = Atomic(bool).init(false);
                var recv_val = Atomic(Event).init(0);
                const receiver = try Thread.spawn(.{}, struct {
                    fn run(c: *Ch, ok: *Atomic(bool), value: *Atomic(Event)) void {
                        Thread.sleep(time.ns_per_ms);
                        const r = c.recv() catch return;
                        ok.store(r.ok, .release);
                        if (r.ok) value.store(r.value, .release);
                    }
                }.run, .{ &ch, &recv_ok, &recv_val });

                const sent = try ch.sendTimeout(0xBEEF, 200);
                try testing.expect(sent.ok);
                receiver.join();
                try testing.expect(recv_ok.load(.acquire));
                try testing.expectEqual(@as(Event, 0xBEEF), recv_val.load(.acquire));

                ch.close();
                const closed = try ch.sendTimeout(0xBEEF, 5);
                try testing.expect(!closed.ok);
            }

            {
                var ch = try Ch.make(allocator, 1);
                defer ch.deinit();

                _ = try ch.send(1);
                try testing.expectError(error.Timeout, ch.sendTimeout(0xD00D, 5));

                var recv_ok = Atomic(bool).init(false);
                var recv_val = Atomic(Event).init(0);
                const receiver = try Thread.spawn(.{}, struct {
                    fn run(c: *Ch, ok: *Atomic(bool), value: *Atomic(Event)) void {
                        Thread.sleep(time.ns_per_ms);
                        const r = c.recv() catch return;
                        ok.store(r.ok, .release);
                        if (r.ok) value.store(r.value, .release);
                    }
                }.run, .{ &ch, &recv_ok, &recv_val });

                const sent = try ch.sendTimeout(0xD00D, 200);
                try testing.expect(sent.ok);
                receiver.join();
                try testing.expect(recv_ok.load(.acquire));
                try testing.expectEqual(@as(Event, 1), recv_val.load(.acquire));

                const queued = try ch.recv();
                try testing.expect(queued.ok);
                try testing.expectEqual(@as(Event, 0xD00D), queued.value);

                ch.close();
                const closed = try ch.sendTimeout(0xBEEF, 5);
                try testing.expect(!closed.ok);
            }
        }

        pub fn testRecvTimeoutContract(allocator: Allocator) !void {
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

        pub fn testRecvWokenByClose(allocator: Allocator) !void {
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

        pub fn testSendWokenByClose(allocator: Allocator) !void {
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

        pub fn testCloseWakesMultiRecv(allocator: Allocator) !void {
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

        pub fn testCloseWakesMultiSend(allocator: Allocator) !void {
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

        pub fn testHighThroughputNoDeadlock(allocator: Allocator) !void {
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

        pub fn testSpscNoDrop(allocator: Allocator) !void {
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

        pub fn testMpscNoDrop(allocator: Allocator) !void {
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

        pub fn testSpmcNoDuplicate(allocator: Allocator) !void {
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

        pub fn testMpmcIntegrity(allocator: Allocator) !void {
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

        pub fn testConcurrentCloseRecv(allocator: Allocator) !void {
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

        pub fn testConcurrentCloseSend(allocator: Allocator) !void {
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

        pub fn testResourceSafetyNormal(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            _ = try ch.send(1);
            _ = try ch.send(2);
            _ = try ch.recv();
            _ = try ch.recv();
            ch.deinit();
        }

        pub fn testResourceSafetyUnconsumed(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            _ = try ch.send(1);
            _ = try ch.send(2);
            _ = try ch.send(3);
            ch.deinit();
        }

        pub fn testResourceSafetyCloseAndDeinit(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 8);
            _ = try ch.send(1);
            ch.close();
            ch.deinit();
        }

        pub fn testRapidCloseRecv(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 4);
            defer ch.deinit();

            ch.close();
            for (0..10) |_| {
                const r = try ch.recv();
                try testing.expect(!r.ok);
            }
        }

        pub fn testRapidCloseSend(allocator: Allocator) !void {
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
        pub fn testBufferedRecvEmptyAfterDrain(allocator: Allocator) !void {
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

        pub fn testUnbufferedInit(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();
        }

        pub fn testUnbufferedRendezvous(allocator: Allocator) !void {
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

        pub fn testUnbufferedSendBlocks(allocator: Allocator) !void {
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

        pub fn testUnbufferedRecvBlocks(allocator: Allocator) !void {
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

        pub fn testUnbufferedMultiRound(allocator: Allocator) !void {
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

        pub fn testUnbufferedCloseWakesRecv(allocator: Allocator) !void {
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

        pub fn testUnbufferedCloseWakesSend(allocator: Allocator) !void {
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

        pub fn testUnbufferedSendAfterClose(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();
            ch.close();

            const s = try ch.send(1);
            try testing.expect(!s.ok);
        }

        pub fn testUnbufferedRecvAfterClose(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            defer ch.deinit();
            ch.close();

            const r = try ch.recv();
            try testing.expect(!r.ok);
        }

        pub fn testUnbufferedSpsc(allocator: Allocator) !void {
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

        pub fn testUnbufferedMpsc(allocator: Allocator) !void {
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

        pub fn testUnbufferedDeinit(allocator: Allocator) !void {
            var ch = try Ch.make(allocator, 0);
            ch.deinit();

            var ch2 = try Ch.make(allocator, 0);
            ch2.close();
            ch2.deinit();
        }
    };
}
