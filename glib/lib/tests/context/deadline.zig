const stdz = @import("stdz");
const testing_mod = @import("testing");
const context_root = @import("context");
const Context = context_root.Context;
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("stores_requested_deadline", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deadlineStoresRequestedDeadlineCase(lib, case_allocator);
                }
            }.run));
            t.run("past_deadline_cancels_immediately", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deadlinePastDeadlineCancelsImmediatelyCase(lib, case_allocator);
                }
            }.run));
            t.run("timeout_wait_returns_deadline_exceeded", testing_mod.TestRunner.fromFn(lib, 40 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deadlineTimeoutWaitReturnsDeadlineExceededCase(lib, case_allocator);
                }
            }.run));
            t.run("manual_cancel_overrides_deadline", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deadlineManualCancelOverridesDeadlineCase(lib, case_allocator);
                }
            }.run));
            t.run("child_inherits_parent_deadline", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deadlineChildInheritsParentDeadlineCase(lib, case_allocator);
                }
            }.run));
            t.run("parent_cancel_propagates_to_deadline_child", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deadlineParentCancelPropagatesToDeadlineChildCase(lib, case_allocator);
                }
            }.run));
            t.run("child_of_elapsed_parent_starts_canceled", testing_mod.TestRunner.fromFn(lib, 40 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deadlineChildOfElapsedParentStartsCanceledCase(lib, case_allocator);
                }
            }.run));
            t.run("attach_observes_parent_cancel_race", testing_mod.TestRunner.fromFn(lib, 40 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deadlineAttachObservesParentCancelRaceCase(lib, case_allocator);
                }
            }.run));
            t.run("spurious_timer_wake_still_waits_for_deadline", testing_mod.TestRunner.fromFn(lib, 64 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deadlineSpuriousTimerWakeStillWaitsForDeadlineCase(lib, case_allocator);
                }
            }.run));
            t.run("spawn_failure_cancels_context", testing_mod.TestRunner.fromFn(lib, 40 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deadlineSpawnFailureCancelsContextCase(lib, case_allocator);
                }
            }.run));
            t.run("deinit_joins_timer_thread", testing_mod.TestRunner.fromFn(lib, 40 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deadlineDeinitJoinsTimerThreadCase(lib, case_allocator);
                }
            }.run));
            t.run("reparented_child_keeps_own_deadline", testing_mod.TestRunner.fromFn(lib, 64 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deadlineReparentedChildKeepsOwnDeadlineCase(lib, case_allocator);
                }
            }.run));
            t.run("parent_cancel_does_not_reenter_shared_lock_under_pending_writer", testing_mod.TestRunner.fromFn(lib, 64 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deadlineParentCancelDoesNotReenterSharedLockUnderPendingWriterCase(lib, case_allocator);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_mod.TestRunner.make(Runner).new(&Holder.runner);
}

fn deadlineStoresRequestedDeadlineCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    const dl = lib.time.nanoTimestamp() + 10000 * lib.time.ns_per_ms;
    var dc = try ctx_ns.withDeadline(bg, dl);
    defer dc.deinit();
    const got = dc.deadline() orelse return error.DeadlineMissing;
    if (got != dl) return error.DeadlineWrongValue;
}

fn deadlinePastDeadlineCancelsImmediatelyCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    const past = lib.time.nanoTimestamp() - 1000 * lib.time.ns_per_ms;
    var dc = try ctx_ns.withDeadline(bg, past);
    defer dc.deinit();
    const e = dc.err() orelse return error.ExpiredDeadlineShouldCancel;
    if (e != error.DeadlineExceeded) return error.ExpiredDeadlineWrongCause;
}

fn deadlineTimeoutWaitReturnsDeadlineExceededCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var dc = try ctx_ns.withTimeout(bg, 100 * lib.time.ns_per_ms);
    defer dc.deinit();
    if (dc.err() != null) return error.TimeoutShouldStartActive;
    const cause = dc.wait(null) orelse return error.TimeoutWaitShouldReturnCause;
    if (cause != error.DeadlineExceeded) return error.TimeoutWaitWrongCause;
}

fn deadlineManualCancelOverridesDeadlineCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var dc = try ctx_ns.withDeadline(bg, lib.time.nanoTimestamp() + 60000 * lib.time.ns_per_ms);
    defer dc.deinit();
    dc.cancel();
    const e = dc.err() orelse return error.ManualCancelDeadlineMissing;
    if (e != error.Canceled) return error.ManualCancelDeadlineWrongCause;
}

fn deadlineChildInheritsParentDeadlineCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    const dl = lib.time.nanoTimestamp() + 10000 * lib.time.ns_per_ms;
    var dc = try ctx_ns.withDeadline(bg, dl);
    defer dc.deinit();
    var cc = try ctx_ns.withCancel(dc);
    defer cc.deinit();
    const got = cc.deadline() orelse return error.InheritDeadlineMissing;
    if (got != dl) return error.InheritDeadlineWrong;
}

fn deadlineParentCancelPropagatesToDeadlineChildCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    defer parent.deinit();
    var dc = try ctx_ns.withDeadline(parent, lib.time.nanoTimestamp() + 60000 * lib.time.ns_per_ms);
    defer dc.deinit();
    if (dc.err() != null) return error.DeadlineChildShouldStartActive;
    parent.cancel();
    const e = dc.err() orelse return error.ParentCancelShouldPropagateToDeadline;
    if (e != error.Canceled) return error.ParentCancelDeadlineWrongCause;
}

fn deadlineChildOfElapsedParentStartsCanceledCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withDeadline(bg, lib.time.nanoTimestamp() + 1 * lib.time.ns_per_ms);
    defer parent.deinit();
    lib.Thread.sleep(5 * lib.time.ns_per_ms);

    var child = try ctx_ns.withDeadline(parent, lib.time.nanoTimestamp() + 60000 * lib.time.ns_per_ms);
    defer child.deinit();
    const e = child.err() orelse return error.ChildOfElapsedParentDeadlineShouldStartCanceled;
    if (e != error.DeadlineExceeded) return error.ChildOfElapsedParentDeadlineWrongCause;
}

fn deadlineAttachObservesParentCancelRaceCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const RaceParent = test_utils.LockCancelParentType(lib);
    var parent_impl: RaceParent = .{};
    const parent = parent_impl.context(allocator);
    parent_impl.cancel_on_next_lock = true;

    var child = try ctx_ns.withDeadline(parent, lib.time.nanoTimestamp() + 1000 * lib.time.ns_per_ms);
    defer child.deinit();

    const e = child.err() orelse return error.DeadlineInitShouldObserveParentCancelDuringAttach;
    if (e != error.BrokenPipe) return error.DeadlineInitParentCancelDuringAttachWrongCause;
}

fn deadlineSpuriousTimerWakeStillWaitsForDeadlineCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var dc = try ctx_ns.withTimeout(bg, 40 * lib.time.ns_per_ms);
    defer dc.deinit();

    const deadline_impl = try dc.as(@TypeOf(ctx_ns).DeadlineContext);

    var timer = try lib.time.Timer.start();
    const t = try lib.Thread.spawn(.{}, struct {
        fn wake(deadline_ctx: *@TypeOf(ctx_ns).DeadlineContext, l: type) void {
            l.Thread.sleep(5 * l.time.ns_per_ms);
            deadline_ctx.timer_cond.signal();
        }
    }.wake, .{ deadline_impl, lib });
    defer t.join();

    const cause = dc.wait(null) orelse return error.DeadlineSpuriousWakeMissing;
    if (cause != error.DeadlineExceeded) return error.DeadlineSpuriousWakeWrongCause;
    if (timer.read() < 20 * lib.time.ns_per_ms) return error.DeadlineTriggeredTooEarlyAfterSpuriousWake;
}

fn deadlineSpawnFailureCancelsContextCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const FailingThread = test_utils.FailingSpawnThreadType(lib);
    const FakeLib = struct {
        pub const Thread = FailingThread;
        pub const time = lib.time;
        pub const mem = lib.mem;
        pub const DoublyLinkedList = lib.DoublyLinkedList;
    };
    const FakeCtxApi = context_root.make(FakeLib);
    var fake_ctx_ns = try FakeCtxApi.init(allocator);
    defer fake_ctx_ns.deinit();

    const bg = fake_ctx_ns.background();
    var dc = try fake_ctx_ns.withTimeout(bg, 1000 * lib.time.ns_per_ms);
    defer dc.deinit();

    const e = dc.err() orelse return error.DeadlineSpawnFailureShouldCancel;
    if (e != error.SystemResources) return error.DeadlineSpawnFailureWrongCause;
}

fn deadlineDeinitJoinsTimerThreadCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CountingThread = test_utils.CountingJoinThreadType(lib);
    const FakeLib = struct {
        pub const Thread = CountingThread;
        pub const time = lib.time;
        pub const mem = lib.mem;
        pub const DoublyLinkedList = lib.DoublyLinkedList;
    };
    const FakeCtxApi = context_root.make(FakeLib);
    var fake_ctx_ns = try FakeCtxApi.init(allocator);
    defer fake_ctx_ns.deinit();

    CountingThread.join_calls = 0;
    const bg = fake_ctx_ns.background();
    var dc = try fake_ctx_ns.withTimeout(bg, 1000 * lib.time.ns_per_ms);
    const impl = try dc.as(@TypeOf(fake_ctx_ns).DeadlineContext);
    if (impl.timer_thread == null) return error.DeadlineTimerShouldStart;
    dc.deinit();
    if (CountingThread.join_calls == 0) return error.DeadlineDeinitShouldJoinTimerThread;
}

fn deadlineReparentedChildKeepsOwnDeadlineCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const ReparentThread = test_utils.ReparentGateThreadType(lib);
    const FakeLib = struct {
        pub const Thread = ReparentThread;
        pub const time = lib.time;
        pub const mem = lib.mem;
        pub const DoublyLinkedList = lib.DoublyLinkedList;
    };
    const FakeCtxApi = context_root.make(FakeLib);
    var fake_ctx_ns = try FakeCtxApi.init(allocator);
    defer fake_ctx_ns.deinit();

    ReparentThread.Condition.resetHooks();
    defer ReparentThread.Condition.resetHooks();

    const bg = fake_ctx_ns.background();
    const ReparentableDeadlineParent = test_utils.ReparentableDeadlineParentType(FakeLib);
    var parent_impl: ReparentableDeadlineParent = .{};
    const parent_deadline = lib.time.nanoTimestamp() + 80 * lib.time.ns_per_ms;
    var parent = parent_impl.context(allocator, bg, parent_deadline);
    ReparentThread.Condition.armTimedWaitHook();
    const child_deadline = lib.time.nanoTimestamp() + 3000 * lib.time.ns_per_ms;
    var child = try fake_ctx_ns.withDeadline(parent, child_deadline);
    defer child.deinit();

    ReparentThread.Condition.waitForTimedWaitHook();

    const reparent_thread = try ReparentThread.spawn(.{}, struct {
        fn deinitParent(ctx: *Context) void {
            ctx.deinit();
        }
    }.deinitParent, .{&parent});

    lib.Thread.sleep(2 * lib.time.ns_per_ms);
    ReparentThread.Condition.releaseTimedWaitHook();
    reparent_thread.join();

    lib.Thread.sleep(120 * lib.time.ns_per_ms);
    const got_deadline = child.deadline() orelse return error.ReparentedDeadlineChildShouldKeepOwnDeadline;
    if (got_deadline != child_deadline) return error.ReparentedDeadlineChildShouldKeepOwnDeadline;
    if (child.err() != null) return error.ReparentedDeadlineChildShouldNotUseOldDeadline;

    child.cancel();
}

fn deadlineParentCancelDoesNotReenterSharedLockUnderPendingWriterCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const TrackingThread = test_utils.SharedLockTrackingThreadType(lib);
    const FakeLib = struct {
        pub const Thread = TrackingThread;
        pub const time = lib.time;
        pub const mem = lib.mem;
        pub const DoublyLinkedList = lib.DoublyLinkedList;
    };
    const FakeCtxApi = context_root.make(FakeLib);
    var fake_ctx_ns = try FakeCtxApi.init(allocator);
    defer fake_ctx_ns.deinit();

    const bg = fake_ctx_ns.background();
    var parent = try fake_ctx_ns.withCancel(bg);
    defer parent.deinit();
    var child = try fake_ctx_ns.withDeadline(parent, lib.time.nanoTimestamp() + 60000 * lib.time.ns_per_ms);
    defer child.deinit();

    const root_lock: *TrackingThread.RwLock = @ptrCast(@alignCast(parent.vtable.treeLockFn(parent.ptr)));
    root_lock.armPendingWriterForTest();
    defer root_lock.clearPendingWriterForTest();

    parent.cancel();

    if (root_lock.nested_shared_while_writer_pending) {
        return error.DeadlinePropagationShouldNotReenterSharedLockUnderPendingWriter;
    }
    const child_err = child.err() orelse return error.DeadlineChildShouldObserveParentCancel;
    if (child_err != error.Canceled) return error.DeadlineChildShouldObserveCanceledCause;
}
