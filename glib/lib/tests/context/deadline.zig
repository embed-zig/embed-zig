const stdz = @import("stdz");
const testing_mod = @import("testing");
const context_root = @import("context");
const time_mod = @import("time");

const Context = context_root.Context;

const context_std = @import("std.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime std: type, comptime time: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("stores_requested_deadline", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deadlineStoresRequestedDeadlineCase(std, time, case_allocator);
                }
            }.run));
            t.run("past_deadline_cancels_immediately", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deadlinePastDeadlineCancelsImmediatelyCase(std, time, case_allocator);
                }
            }.run));
            t.run("timeout_wait_returns_deadline_exceeded", testing_mod.TestRunner.fromFn(std, 40 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deadlineTimeoutWaitReturnsDeadlineExceededCase(std, time, case_allocator);
                }
            }.run));
            t.run("manual_cancel_overrides_deadline", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deadlineManualCancelOverridesDeadlineCase(std, time, case_allocator);
                }
            }.run));
            t.run("child_inherits_parent_deadline", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deadlineChildInheritsParentDeadlineCase(std, time, case_allocator);
                }
            }.run));
            t.run("parent_cancel_propagates_to_deadline_child", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deadlineParentCancelPropagatesToDeadlineChildCase(std, time, case_allocator);
                }
            }.run));
            t.run("child_of_elapsed_parent_starts_canceled", testing_mod.TestRunner.fromFn(std, 40 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deadlineChildOfElapsedParentStartsCanceledCase(std, time, case_allocator);
                }
            }.run));
            t.run("attach_observes_parent_cancel_race", testing_mod.TestRunner.fromFn(std, 40 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deadlineAttachObservesParentCancelRaceCase(std, time, case_allocator);
                }
            }.run));
            t.run("spurious_timer_wake_still_waits_for_deadline", testing_mod.TestRunner.fromFn(std, 64 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deadlineSpuriousTimerWakeStillWaitsForDeadlineCase(std, time, case_allocator);
                }
            }.run));
            t.run("spawn_failure_cancels_context", testing_mod.TestRunner.fromFn(std, 40 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deadlineSpawnFailureCancelsContextCase(std, time, case_allocator);
                }
            }.run));
            t.run("deinit_joins_timer_thread", testing_mod.TestRunner.fromFn(std, 40 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deadlineDeinitJoinsTimerThreadCase(std, time, case_allocator);
                }
            }.run));
            t.run("reparented_child_keeps_own_deadline", testing_mod.TestRunner.fromFn(std, 64 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deadlineReparentedChildKeepsOwnDeadlineCase(std, time, case_allocator);
                }
            }.run));
            t.run("parent_cancel_does_not_reenter_shared_lock_under_pending_writer", testing_mod.TestRunner.fromFn(std, 64 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deadlineParentCancelDoesNotReenterSharedLockUnderPendingWriterCase(std, time, case_allocator);
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

fn deadlineStoresRequestedDeadlineCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    const dl = time_mod.instant.add(ctx_api.now(), 10000 * time_mod.duration.MilliSecond);
    var dc = try ctx_api.withDeadline(bg, dl);
    defer dc.deinit();
    const got = dc.deadline() orelse return error.DeadlineMissing;
    if (got != dl) return error.DeadlineWrongValue;
}

fn deadlinePastDeadlineCancelsImmediatelyCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    const past = time_mod.instant.add(ctx_api.now(), -1000 * time_mod.duration.MilliSecond);
    var dc = try ctx_api.withDeadline(bg, past);
    defer dc.deinit();
    const e = dc.err() orelse return error.ExpiredDeadlineShouldCancel;
    if (e != error.DeadlineExceeded) return error.ExpiredDeadlineWrongCause;
}

fn deadlineTimeoutWaitReturnsDeadlineExceededCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var dc = try ctx_api.withTimeout(bg, 100 * time_mod.duration.MilliSecond);
    defer dc.deinit();
    if (dc.err() != null) return error.TimeoutShouldStartActive;
    const cause = dc.wait(null) orelse return error.TimeoutWaitShouldReturnCause;
    if (cause != error.DeadlineExceeded) return error.TimeoutWaitWrongCause;
}

fn deadlineManualCancelOverridesDeadlineCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var dc = try ctx_api.withDeadline(bg, time_mod.instant.add(ctx_api.now(), 60000 * time_mod.duration.MilliSecond));
    defer dc.deinit();
    dc.cancel();
    const e = dc.err() orelse return error.ManualCancelDeadlineMissing;
    if (e != error.Canceled) return error.ManualCancelDeadlineWrongCause;
}

fn deadlineChildInheritsParentDeadlineCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    const dl = time_mod.instant.add(ctx_api.now(), 10000 * time_mod.duration.MilliSecond);
    var dc = try ctx_api.withDeadline(bg, dl);
    defer dc.deinit();
    var cc = try ctx_api.withCancel(dc);
    defer cc.deinit();
    const got = cc.deadline() orelse return error.InheritDeadlineMissing;
    if (got != dl) return error.InheritDeadlineWrong;
}

fn deadlineParentCancelPropagatesToDeadlineChildCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var parent = try ctx_api.withCancel(bg);
    defer parent.deinit();
    var dc = try ctx_api.withDeadline(parent, time_mod.instant.add(ctx_api.now(), 60000 * time_mod.duration.MilliSecond));
    defer dc.deinit();
    if (dc.err() != null) return error.DeadlineChildShouldStartActive;
    parent.cancel();
    const e = dc.err() orelse return error.ParentCancelShouldPropagateToDeadline;
    if (e != error.Canceled) return error.ParentCancelDeadlineWrongCause;
}

fn deadlineChildOfElapsedParentStartsCanceledCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var parent = try ctx_api.withDeadline(bg, time_mod.instant.add(ctx_api.now(), 1 * time_mod.duration.MilliSecond));
    defer parent.deinit();
    std.Thread.sleep(@intCast(5 * time_mod.duration.MilliSecond));

    var child = try ctx_api.withDeadline(parent, time_mod.instant.add(ctx_api.now(), 60000 * time_mod.duration.MilliSecond));
    defer child.deinit();
    const e = child.err() orelse return error.ChildOfElapsedParentDeadlineShouldStartCanceled;
    if (e != error.DeadlineExceeded) return error.ChildOfElapsedParentDeadlineWrongCause;
}

fn deadlineAttachObservesParentCancelRaceCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const RaceParent = test_utils.LockCancelParentType(std);
    var parent_impl: RaceParent = .{};
    const parent = parent_impl.context(allocator);
    parent_impl.cancel_on_next_lock = true;

    var child = try ctx_api.withDeadline(parent, time_mod.instant.add(ctx_api.now(), 1000 * time_mod.duration.MilliSecond));
    defer child.deinit();

    const e = child.err() orelse return error.DeadlineInitShouldObserveParentCancelDuringAttach;
    if (e != error.BrokenPipe) return error.DeadlineInitParentCancelDuringAttachWrongCause;
}

fn deadlineSpuriousTimerWakeStillWaitsForDeadlineCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var dc = try ctx_api.withTimeout(bg, 40 * time_mod.duration.MilliSecond);
    defer dc.deinit();

    const deadline_impl = try dc.as(@TypeOf(ctx_api).DeadlineContext);

    const started = time.instant.now();
    const t = try std.Thread.spawn(.{}, struct {
        fn wake(deadline_ctx: *@TypeOf(ctx_api).DeadlineContext, l: type) void {
            l.Thread.sleep(@intCast(5 * time_mod.duration.MilliSecond));
            deadline_ctx.timer_cond.signal();
        }
    }.wake, .{ deadline_impl, std });
    defer t.join();

    const cause = dc.wait(null) orelse return error.DeadlineSpuriousWakeMissing;
    if (cause != error.DeadlineExceeded) return error.DeadlineSpuriousWakeWrongCause;
    const elapsed = time_mod.instant.sub(time.instant.now(), started);
    if (elapsed < 20 * time_mod.duration.MilliSecond) return error.DeadlineTriggeredTooEarlyAfterSpuriousWake;
}

fn deadlineSpawnFailureCancelsContextCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const FailingThread = context_std.FailingThread.make(std);
    const FakeLib = context_std.make(std, .{ .Thread = FailingThread });
    const FakeCtxApi = context_root.make(FakeLib, time);
    var fake_ctx_api = try FakeCtxApi.init(allocator);
    defer fake_ctx_api.deinit();

    const bg = fake_ctx_api.background();
    var dc = try fake_ctx_api.withTimeout(bg, 1000 * time_mod.duration.MilliSecond);
    defer dc.deinit();

    const e = dc.err() orelse return error.DeadlineSpawnFailureShouldCancel;
    if (e != error.SystemResources) return error.DeadlineSpawnFailureWrongCause;
}

fn deadlineDeinitJoinsTimerThreadCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CountingThread = test_utils.CountingJoinThreadType(std);
    const FakeLib = context_std.make(std, .{ .Thread = CountingThread });
    const FakeCtxApi = context_root.make(FakeLib, time);
    var fake_ctx_api = try FakeCtxApi.init(allocator);
    defer fake_ctx_api.deinit();

    CountingThread.join_calls = 0;
    const bg = fake_ctx_api.background();
    var dc = try fake_ctx_api.withTimeout(bg, 1000 * time_mod.duration.MilliSecond);
    const impl = try dc.as(@TypeOf(fake_ctx_api).DeadlineContext);
    if (impl.timer_thread == null) return error.DeadlineTimerShouldStart;
    dc.deinit();
    if (CountingThread.join_calls == 0) return error.DeadlineDeinitShouldJoinTimerThread;
}

fn deadlineReparentedChildKeepsOwnDeadlineCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const ReparentThread = test_utils.ReparentGateThreadType(std);
    const FakeLib = context_std.make(std, .{ .Thread = ReparentThread });
    const FakeCtxApi = context_root.make(FakeLib, time);
    var fake_ctx_api = try FakeCtxApi.init(allocator);
    defer fake_ctx_api.deinit();

    ReparentThread.Condition.resetHooks();
    defer ReparentThread.Condition.resetHooks();

    const bg = fake_ctx_api.background();
    const ReparentableDeadlineParent = test_utils.ReparentableDeadlineParentType(FakeLib);
    var parent_impl: ReparentableDeadlineParent = .{};
    const parent_deadline = time_mod.instant.add(fake_ctx_api.now(), 80 * time_mod.duration.MilliSecond);
    var parent = parent_impl.context(allocator, bg, parent_deadline);
    ReparentThread.Condition.armTimedWaitHook();
    const child_deadline = time_mod.instant.add(fake_ctx_api.now(), 3000 * time_mod.duration.MilliSecond);
    var child = try fake_ctx_api.withDeadline(parent, child_deadline);
    defer child.deinit();

    ReparentThread.Condition.waitForTimedWaitHook();

    const reparent_thread = try ReparentThread.spawn(.{}, struct {
        fn deinitParent(ctx: *Context) void {
            ctx.deinit();
        }
    }.deinitParent, .{&parent});

    std.Thread.sleep(@intCast(2 * time_mod.duration.MilliSecond));
    ReparentThread.Condition.releaseTimedWaitHook();
    reparent_thread.join();

    std.Thread.sleep(@intCast(120 * time_mod.duration.MilliSecond));
    const got_deadline = child.deadline() orelse return error.ReparentedDeadlineChildShouldKeepOwnDeadline;
    if (got_deadline != child_deadline) return error.ReparentedDeadlineChildShouldKeepOwnDeadline;
    if (child.err() != null) return error.ReparentedDeadlineChildShouldNotUseOldDeadline;

    child.cancel();
}

fn deadlineParentCancelDoesNotReenterSharedLockUnderPendingWriterCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const TrackingThread = test_utils.SharedLockTrackingThreadType(std);
    const FakeLib = context_std.make(std, .{ .Thread = TrackingThread });
    const FakeCtxApi = context_root.make(FakeLib, time);
    var fake_ctx_api = try FakeCtxApi.init(allocator);
    defer fake_ctx_api.deinit();
    TrackingThread.Condition.resetHooks();
    defer TrackingThread.Condition.resetHooks();

    const bg = fake_ctx_api.background();
    var parent = try fake_ctx_api.withCancel(bg);
    defer parent.deinit();
    TrackingThread.Condition.armTimedWaitHook();
    var child = try fake_ctx_api.withDeadline(parent, time_mod.instant.add(fake_ctx_api.now(), 60000 * time_mod.duration.MilliSecond));
    defer child.deinit();
    TrackingThread.Condition.waitForTimedWaitHook();
    TrackingThread.Condition.releaseTimedWaitHook();

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
