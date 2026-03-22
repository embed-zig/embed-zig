//! Context test runner — exercises cancel propagation, value passing, deadlines, and wait.
//!
//! Accepts any type with the same shape as std (lib.Thread, lib.time, etc.).
//! The main test logic lives in `run(lib)`, so it can be reused from firmware
//! or other non-`zig test` entry points. This file may still include local
//! `test` blocks for std-based execution.
//!
//! Usage:
//!   try @import("context").test_runner.context.run(std);
//!   try @import("context").test_runner.context.run(embed);

const root = @import("../../context.zig");
const Context = root.Context;
const root_deinit_assert_env = "EMBED_CONTEXT_EXPECT_ROOT_DEINIT_ASSERT";
const root_deinit_missing_assert_exit_code = 42;

pub fn run(comptime lib: type) !void {
    const log = lib.log.scoped(.context);

    log.info("=== context test_runner start ===", .{});

    try backgroundTests(lib);
    try cancelBasicTests(lib);
    try cancelCauseTests(lib);
    try cancelPropagationTests(lib);
    try valueTests(lib);
    try lifecycleTests(lib);
    try deadlineTests(lib);
    try waitTests(lib);
    try multiThreadTests(lib);

    log.info("=== context test_runner done ===", .{});
}

// ---------------------------------------------------------------------------
// Background
// ---------------------------------------------------------------------------

fn backgroundTests(comptime lib: type) !void {
    const log = lib.log.scoped(.context);
    const CtxApi = root.Make(lib);
    var ctx_ns = try CtxApi.init(lib.testing.allocator);
    defer ctx_ns.deinit();

    {
        const bg = ctx_ns.background();
        if (bg.err() != null) return error.BackgroundShouldNotBeDone;
    }

    {
        var key: Context.Key(u64) = .{};
        const bg = ctx_ns.background();
        if (bg.value(u64, &key) != null) return error.BackgroundShouldHaveNoValues;
    }

    {
        const bg = ctx_ns.background();
        if (bg.deadline() != null) return error.BackgroundShouldHaveNoDeadline;
    }

    {
        const CapturingThread = CapturingSleepThreadType(lib);
        const FakeLib = struct {
            pub const Thread = CapturingThread;
            pub const time = lib.time;
            pub const mem = lib.mem;
            pub const DoublyLinkedList = lib.DoublyLinkedList;
        };
        const FakeCtxApi = root.Make(FakeLib);
        var fake_ctx_ns = try FakeCtxApi.init(lib.testing.allocator);
        defer fake_ctx_ns.deinit();

        CapturingThread.sleep_calls = 0;
        CapturingThread.last_sleep_ns = 0;
        if (fake_ctx_ns.background().wait(5) != null) return error.BackgroundWaitShouldReturnNull;
        if (CapturingThread.sleep_calls == 0) return error.BackgroundWaitShouldUseLibThreadSleep;
        if (CapturingThread.last_sleep_ns != 5 * lib.time.ns_per_ms) return error.BackgroundWaitWrongSleepDuration;
    }

    log.info("background ok", .{});
}

// ---------------------------------------------------------------------------
// Cancel: basic
// ---------------------------------------------------------------------------

fn cancelBasicTests(comptime lib: type) !void {
    const log = lib.log.scoped(.context);
    const CtxApi = root.Make(lib);
    var ctx_ns = try CtxApi.init(lib.testing.allocator);
    defer ctx_ns.deinit();

    {
        const bg = ctx_ns.background();
        var cc = try ctx_ns.withCancel(bg);
        defer cc.deinit();
        if (cc.err() != null) return error.ErrBeforeCancelShouldBeNull;
    }

    {
        const bg = ctx_ns.background();
        var cc = try ctx_ns.withCancel(bg);
        defer cc.deinit();
        cc.cancel();
        const e = cc.err() orelse return error.ErrAfterCancelShouldExist;
        if (e != error.Canceled) return error.ErrAfterCancelWrongValue;
    }

    {
        const bg = ctx_ns.background();
        var cc = try ctx_ns.withCancel(bg);
        defer cc.deinit();
        cc.cancel();
        cc.cancel();
        cc.cancel();
        const e = cc.err() orelse return error.IdempotentCancelFailed;
        if (e != error.Canceled) return error.IdempotentCancelWrongValue;
    }

    {
        const bg = ctx_ns.background();
        var cc = try ctx_ns.withCancel(bg);
        defer cc.deinit();
        if (cc.deadline() != null) return error.CancelShouldHaveNoDeadline;
    }

    log.info("cancel basic ok", .{});
}

// ---------------------------------------------------------------------------
// Cancel: cause
// ---------------------------------------------------------------------------

fn cancelCauseTests(comptime lib: type) !void {
    const log = lib.log.scoped(.context);
    const CtxApi = root.Make(lib);
    var ctx_ns = try CtxApi.init(lib.testing.allocator);
    defer ctx_ns.deinit();

    {
        const bg = ctx_ns.background();
        var cc = try ctx_ns.withCancel(bg);
        defer cc.deinit();
        cc.cancelWithCause(error.TimedOut);
        const e = cc.err() orelse return error.CauseShouldExist;
        if (e != error.TimedOut) return error.CauseWrongValue;
    }

    {
        const bg = ctx_ns.background();
        var cc = try ctx_ns.withCancel(bg);
        defer cc.deinit();
        cc.cancelWithCause(error.TimedOut);
        cc.cancelWithCause(error.BrokenPipe);
        const e = cc.err() orelse return error.FirstCauseShouldWin;
        if (e != error.TimedOut) return error.FirstCauseWrongValue;
    }

    {
        const bg = ctx_ns.background();
        var parent = try ctx_ns.withCancel(bg);
        defer parent.deinit();
        var child = try ctx_ns.withCancel(parent);
        defer child.deinit();
        parent.cancelWithCause(error.ConnectionReset);
        const pe = parent.err() orelse return error.ParentCauseMissing;
        const ce = child.err() orelse return error.ChildCauseMissing;
        if (pe != error.ConnectionReset) return error.ParentCauseWrong;
        if (ce != error.ConnectionReset) return error.ChildCauseWrong;
    }

    log.info("cancel cause ok", .{});
}

// ---------------------------------------------------------------------------
// Cancel: propagation
// ---------------------------------------------------------------------------

fn cancelPropagationTests(comptime lib: type) !void {
    const log = lib.log.scoped(.context);
    const CtxApi = root.Make(lib);
    var ctx_ns = try CtxApi.init(lib.testing.allocator);
    defer ctx_ns.deinit();

    {
        const bg = ctx_ns.background();
        var parent = try ctx_ns.withCancel(bg);
        defer parent.deinit();
        var child = try ctx_ns.withCancel(parent);
        defer child.deinit();
        if (child.err() != null) return error.ChildShouldStartActive;
        parent.cancel();
        if (parent.err() == null) return error.ParentShouldBeCanceled;
        if (child.err() == null) return error.ChildShouldBeCanceled;
    }

    {
        const bg = ctx_ns.background();
        var a = try ctx_ns.withCancel(bg);
        defer a.deinit();
        var b = try ctx_ns.withCancel(a);
        defer b.deinit();
        var c = try ctx_ns.withCancel(b);
        defer c.deinit();
        if (c.err() != null) return error.ThreeLevelShouldStartActive;
        a.cancel();
        if (a.err() == null) return error.ThreeLevelANotCanceled;
        if (b.err() == null) return error.ThreeLevelBNotCanceled;
        if (c.err() == null) return error.ThreeLevelCNotCanceled;
    }

    {
        const bg = ctx_ns.background();
        var parent = try ctx_ns.withCancel(bg);
        defer parent.deinit();
        var child = try ctx_ns.withCancel(parent);
        defer child.deinit();
        child.cancel();
        if (child.err() == null) return error.ChildCancelFailed;
        if (parent.err() != null) return error.ChildCancelAffectedParent;
    }

    {
        const bg = ctx_ns.background();
        var parent = try ctx_ns.withCancel(bg);
        defer parent.deinit();
        var a = try ctx_ns.withCancel(parent);
        defer a.deinit();
        var b = try ctx_ns.withCancel(parent);
        defer b.deinit();
        a.cancel();
        if (a.err() == null) return error.SiblingACancelFailed;
        if (b.err() != null) return error.SiblingBShouldBeActive;
        parent.cancel();
        if (b.err() == null) return error.SiblingBShouldBeCanceled;
    }

    {
        const bg = ctx_ns.background();
        var parent = try ctx_ns.withCancel(bg);
        defer parent.deinit();
        {
            var child = try ctx_ns.withCancel(parent);
            child.deinit();
        }
        parent.cancel();
    }

    {
        const bg = ctx_ns.background();
        var a = try ctx_ns.withCancel(bg);
        defer a.deinit();
        var b = try ctx_ns.withCancel(a);
        var c = try ctx_ns.withCancel(b);
        defer c.deinit();
        var d = try ctx_ns.withCancel(b);
        defer d.deinit();

        b.deinit();
        a.cancelWithCause(error.BrokenPipe);

        const ce = c.err() orelse return error.ReparentedCShouldBeCanceled;
        const de = d.err() orelse return error.ReparentedDShouldBeCanceled;
        if (ce != error.BrokenPipe) return error.ReparentedCWrongCause;
        if (de != error.BrokenPipe) return error.ReparentedDWrongCause;
    }

    {
        const bg = ctx_ns.background();
        var parent = try ctx_ns.withCancel(bg);
        defer parent.deinit();
        parent.cancelWithCause(error.TimedOut);
        var child = try ctx_ns.withCancel(parent);
        defer child.deinit();
        const e = child.err() orelse return error.ChildOfCanceledShouldStart;
        if (e != error.TimedOut) return error.ChildOfCanceledWrongCause;
    }

    log.info("cancel propagation ok", .{});
}

// ---------------------------------------------------------------------------
// Value
// ---------------------------------------------------------------------------

fn valueTests(comptime lib: type) !void {
    const log = lib.log.scoped(.context);
    const CtxApi = root.Make(lib);
    var ctx_ns = try CtxApi.init(lib.testing.allocator);
    defer ctx_ns.deinit();

    {
        var key: Context.Key(u64) = .{};
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withValue(u64, bg, &key, 42);
        defer ctx.deinit();
        const val = ctx.value(u64, &key) orelse return error.ValueBasicGetFailed;
        if (val != 42) return error.ValueBasicGetWrong;
    }

    {
        var key_a: Context.Key(u64) = .{};
        var key_b: Context.Key(u64) = .{};
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withValue(u64, bg, &key_a, 42);
        defer ctx.deinit();
        if (ctx.value(u64, &key_b) != null) return error.MissingKeyShouldBeNull;
    }

    {
        var id_key: Context.Key(u64) = .{};
        var name_key: Context.Key(u32) = .{};
        const bg = ctx_ns.background();
        var vc1 = try ctx_ns.withValue(u64, bg, &id_key, 100);
        defer vc1.deinit();
        var ctx = try ctx_ns.withValue(u32, vc1, &name_key, 200);
        defer ctx.deinit();
        const id = ctx.value(u64, &id_key) orelse return error.ChainLookupIdFailed;
        const name = ctx.value(u32, &name_key) orelse return error.ChainLookupNameFailed;
        if (id != 100) return error.ChainLookupIdWrong;
        if (name != 200) return error.ChainLookupNameWrong;
    }

    {
        var key: Context.Key(u64) = .{};
        const bg = ctx_ns.background();
        var vc1 = try ctx_ns.withValue(u64, bg, &key, 1);
        defer vc1.deinit();
        var ctx = try ctx_ns.withValue(u64, vc1, &key, 2);
        defer ctx.deinit();
        const val = ctx.value(u64, &key) orelse return error.ShadowingFailed;
        if (val != 2) return error.ShadowingWrongValue;
    }

    {
        var key: Context.Key(u64) = .{};
        const bg = ctx_ns.background();
        var cc = try ctx_ns.withCancel(bg);
        defer cc.deinit();
        var ctx = try ctx_ns.withValue(u64, cc, &key, 42);
        defer ctx.deinit();
        if (ctx.err() != null) return error.ValueErrBeforeCancelShouldBeNull;
        cc.cancelWithCause(error.TimedOut);
        const e = ctx.err() orelse return error.ValueErrAfterCancelMissing;
        if (e != error.TimedOut) return error.ValueErrAfterCancelWrong;
    }

    {
        var key: Context.Key(u64) = .{};
        const bg = ctx_ns.background();
        var parent_cc = try ctx_ns.withCancel(bg);
        defer parent_cc.deinit();
        var vc = try ctx_ns.withValue(u64, parent_cc, &key, 99);
        defer vc.deinit();
        var child_cc = try ctx_ns.withCancel(vc);
        defer child_cc.deinit();
        if (child_cc.err() != null) return error.CancelThroughValueShouldStart;
        parent_cc.cancel();
        if (child_cc.err() == null) return error.CancelThroughValueFailed;
        const val = child_cc.value(u64, &key) orelse return error.CancelThroughValueLookupFailed;
        if (val != 99) return error.CancelThroughValueLookupWrong;
    }

    {
        var key: Context.Key(u64) = .{};
        const bg = ctx_ns.background();
        var parent_cc = try ctx_ns.withCancel(bg);
        defer parent_cc.deinit();
        var vc = try ctx_ns.withValue(u64, parent_cc, &key, 77);
        var child_cc = try ctx_ns.withCancel(vc);
        defer child_cc.deinit();

        const before = child_cc.value(u64, &key) orelse return error.ValueBeforeDeinitMissing;
        if (before != 77) return error.ValueBeforeDeinitWrong;

        vc.deinit();

        if (child_cc.value(u64, &key) != null) return error.ValueShouldDropAfterValueContextDeinit;
        parent_cc.cancel();
        if (child_cc.err() == null) return error.ChildShouldSurviveValueDeinitReparent;
    }

    {
        var key: Context.Key(u64) = .{};
        const bg = ctx_ns.background();
        var parent_cc = try ctx_ns.withCancel(bg);
        defer parent_cc.deinit();
        var vc = try ctx_ns.withValue(u64, parent_cc, &key, 55);
        defer vc.deinit();
        var child_cc = try ctx_ns.withCancel(vc);
        defer child_cc.deinit();

        vc.cancel();
        vc.cancelWithCause(error.BrokenPipe);

        if (vc.err() != null) return error.ValueCancelShouldNotSetErr;
        if (child_cc.err() != null) return error.ValueCancelShouldNotAffectChildren;

        parent_cc.cancelWithCause(error.TimedOut);
        const child_err = child_cc.err() orelse return error.ParentCancelShouldStillPropagateAfterValueCancel;
        if (child_err != error.TimedOut) return error.ParentCancelAfterValueCancelWrongCause;
    }

    log.info("value ok", .{});
}

// ---------------------------------------------------------------------------
// Lifecycle / ownership
// ---------------------------------------------------------------------------

fn lifecycleTests(comptime lib: type) !void {
    const log = lib.log.scoped(.context);
    const testing = lib.testing;
    const CtxApi = root.Make(lib);

    {
        var ctx_ns = try CtxApi.init(testing.allocator);
        const bg = ctx_ns.background();
        var child = try ctx_ns.withCancel(bg);

        // Root deinit is only valid once the tree is empty. The active child
        // remains linked under background until explicitly deinitialized.
        try testing.expect(ctx_ns.shared.background_impl.tree.children.first != null);

        child.deinit();
        try testing.expect(ctx_ns.shared.background_impl.tree.children.first == null);

        ctx_ns.deinit();
    }

    {
        var ctx_ns = try CtxApi.init(testing.allocator);
        const bg = ctx_ns.background();
        var parent = try ctx_ns.withCancel(bg);
        var child = try ctx_ns.withCancel(parent);

        parent.deinit();
        try testing.expect(ctx_ns.shared.background_impl.tree.children.first != null);

        child.deinit();
        try testing.expect(ctx_ns.shared.background_impl.tree.children.first == null);

        ctx_ns.deinit();
    }

    log.info("lifecycle ok", .{});
}

// ---------------------------------------------------------------------------
// Deadline / Timeout
// ---------------------------------------------------------------------------

fn deadlineTests(comptime lib: type) !void {
    const log = lib.log.scoped(.context);
    const CtxApi = root.Make(lib);
    var ctx_ns = try CtxApi.init(lib.testing.allocator);
    defer ctx_ns.deinit();
    const testing = lib.testing;

    {
        const bg = ctx_ns.background();
        const dl = lib.time.milliTimestamp() + 10000;
        var dc = try ctx_ns.withDeadline(bg, dl);
        defer dc.deinit();
        const got = dc.deadline() orelse return error.DeadlineMissing;
        if (got != dl) return error.DeadlineWrongValue;
    }

    {
        const bg = ctx_ns.background();
        const past = lib.time.milliTimestamp() - 1000;
        var dc = try ctx_ns.withDeadline(bg, past);
        defer dc.deinit();
        const e = dc.err() orelse return error.ExpiredDeadlineShouldCancel;
        if (e != error.DeadlineExceeded) return error.ExpiredDeadlineWrongCause;
    }

    {
        const bg = ctx_ns.background();
        var dc = try ctx_ns.withTimeout(bg, 100);
        defer dc.deinit();
        if (dc.err() != null) return error.TimeoutShouldStartActive;
        const cause = dc.wait(null) orelse return error.TimeoutWaitShouldReturnCause;
        if (cause != error.DeadlineExceeded) return error.TimeoutWaitWrongCause;
    }

    {
        const bg = ctx_ns.background();
        var dc = try ctx_ns.withDeadline(bg, lib.time.milliTimestamp() + 60000);
        defer dc.deinit();
        dc.cancel();
        const e = dc.err() orelse return error.ManualCancelDeadlineMissing;
        if (e != error.Canceled) return error.ManualCancelDeadlineWrongCause;
    }

    {
        const bg = ctx_ns.background();
        const dl = lib.time.milliTimestamp() + 10000;
        var dc = try ctx_ns.withDeadline(bg, dl);
        defer dc.deinit();
        var cc = try ctx_ns.withCancel(dc);
        defer cc.deinit();
        const got = cc.deadline() orelse return error.InheritDeadlineMissing;
        if (got != dl) return error.InheritDeadlineWrong;
    }

    {
        const bg = ctx_ns.background();
        var parent = try ctx_ns.withCancel(bg);
        defer parent.deinit();
        var dc = try ctx_ns.withDeadline(parent, lib.time.milliTimestamp() + 60000);
        defer dc.deinit();
        if (dc.err() != null) return error.DeadlineChildShouldStartActive;
        parent.cancel();
        const e = dc.err() orelse return error.ParentCancelShouldPropagateToDeadline;
        if (e != error.Canceled) return error.ParentCancelDeadlineWrongCause;
    }

    {
        const bg = ctx_ns.background();
        var parent = try ctx_ns.withDeadline(bg, lib.time.milliTimestamp() + 1);
        defer parent.deinit();
        lib.Thread.sleep(5 * lib.time.ns_per_ms);

        var child = try ctx_ns.withDeadline(parent, lib.time.milliTimestamp() + 60000);
        defer child.deinit();
        const e = child.err() orelse return error.ChildOfElapsedParentDeadlineShouldStartCanceled;
        if (e != error.DeadlineExceeded) return error.ChildOfElapsedParentDeadlineWrongCause;
    }

    {
        const bg = ctx_ns.background();
        var dc = try ctx_ns.withTimeout(bg, 40);
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

    {
        const FailingThread = FailingSpawnThreadType(lib);
        const FakeLib = struct {
            pub const Thread = FailingThread;
            pub const time = lib.time;
            pub const mem = lib.mem;
            pub const DoublyLinkedList = lib.DoublyLinkedList;
        };
        const FakeCtxApi = root.Make(FakeLib);
        var fake_ctx_ns = try FakeCtxApi.init(testing.allocator);
        defer fake_ctx_ns.deinit();

        const bg = fake_ctx_ns.background();
        var dc = try fake_ctx_ns.withTimeout(bg, 1000);
        defer dc.deinit();

        const e = dc.err() orelse return error.DeadlineSpawnFailureShouldCancel;
        if (e != error.SystemResources) return error.DeadlineSpawnFailureWrongCause;
    }

    {
        const CountingThread = CountingJoinThreadType(lib);
        const FakeLib = struct {
            pub const Thread = CountingThread;
            pub const time = lib.time;
            pub const mem = lib.mem;
            pub const DoublyLinkedList = lib.DoublyLinkedList;
        };
        const FakeCtxApi = root.Make(FakeLib);
        var fake_ctx_ns = try FakeCtxApi.init(testing.allocator);
        defer fake_ctx_ns.deinit();

        CountingThread.join_calls = 0;
        const bg = fake_ctx_ns.background();
        var dc = try fake_ctx_ns.withTimeout(bg, 1000);
        const impl = try dc.as(@TypeOf(fake_ctx_ns).DeadlineContext);
        if (impl.timer_thread == null) return error.DeadlineTimerShouldStart;
        dc.deinit();
        if (CountingThread.join_calls == 0) return error.DeadlineDeinitShouldJoinTimerThread;
    }

    log.info("deadline ok", .{});
}

// ---------------------------------------------------------------------------
// Wait (via Context VTable)
// ---------------------------------------------------------------------------

fn waitTests(comptime lib: type) !void {
    const log = lib.log.scoped(.context);
    const CtxApi = root.Make(lib);
    var ctx_ns = try CtxApi.init(lib.testing.allocator);
    defer ctx_ns.deinit();

    {
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withCancel(bg);
        defer ctx.deinit();
        ctx.cancel();
        const cause = ctx.wait(null) orelse return error.WaitAfterCancelShouldReturn;
        if (cause != error.Canceled) return error.WaitAfterCancelWrongCause;
    }

    {
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withCancel(bg);
        defer ctx.deinit();
        if (ctx.wait(50) != null) return error.WaitTimeoutShouldReturnNull;
    }

    {
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withCancel(bg);
        defer ctx.deinit();
        const cancel_impl = try ctx.as(@TypeOf(ctx_ns).CancelContext);

        var timer = try lib.time.Timer.start();
        const t = try lib.Thread.spawn(.{}, struct {
            fn wake(cancel_ctx: *@TypeOf(ctx_ns).CancelContext, l: type) void {
                l.Thread.sleep(5 * l.time.ns_per_ms);
                cancel_ctx.cond.signal();
            }
        }.wake, .{ cancel_impl, lib });
        defer t.join();

        if (ctx.wait(40) != null) return error.WaitSpuriousWakeShouldReturnNull;
        if (timer.read() < 20 * lib.time.ns_per_ms) return error.WaitReturnedTooEarlyAfterSpuriousWake;
    }

    {
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withCancel(bg);
        defer ctx.deinit();
        ctx.cancelWithCause(error.TimedOut);
        const cause = ctx.wait(50) orelse return error.WaitAlreadyCanceledMissing;
        if (cause != error.TimedOut) return error.WaitAlreadyCanceledWrongCause;
    }

    {
        var key: Context.Key(u64) = .{};
        const bg = ctx_ns.background();
        var cc = try ctx_ns.withCancel(bg);
        defer cc.deinit();
        var ctx = try ctx_ns.withValue(u64, cc, &key, 42);
        defer ctx.deinit();
        cc.cancel();
        const cause = ctx.wait(100) orelse return error.WaitThroughValueMissing;
        if (cause != error.Canceled) return error.WaitThroughValueWrongCause;
    }

    {
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withTimeout(bg, 100);
        defer ctx.deinit();
        const cause = ctx.wait(null) orelse return error.WaitDeadlineVtableMissing;
        if (cause != error.DeadlineExceeded) return error.WaitDeadlineVtableWrongCause;
    }

    {
        const bg = ctx_ns.background();
        if (bg.wait(50) != null) return error.BackgroundWaitShouldReturnNull;
    }

    log.info("wait ok", .{});
}

// ---------------------------------------------------------------------------
// Multi-thread
// ---------------------------------------------------------------------------

fn multiThreadTests(comptime lib: type) !void {
    const log = lib.log.scoped(.context);
    const CtxApi = root.Make(lib);
    var ctx_ns = try CtxApi.init(lib.testing.allocator);
    defer ctx_ns.deinit();

    {
        const bg = ctx_ns.background();
        var cc = try ctx_ns.withCancel(bg);
        defer cc.deinit();

        const t = try lib.Thread.spawn(.{}, struct {
            fn work(c: *Context) void {
                const cause = c.wait(null);
                lib.debug.assert(cause != null);
                lib.debug.assert(cause.? == error.Canceled);
            }
        }.work, .{&cc});

        lib.Thread.sleep(5_000_000);
        cc.cancel();
        t.join();

        const e = cc.err() orelse return error.MultiThreadCancelMissing;
        if (e != error.Canceled) return error.MultiThreadCancelWrong;
    }

    {
        const bg = ctx_ns.background();
        var cc = try ctx_ns.withCancel(bg);
        defer cc.deinit();

        const t = try lib.Thread.spawn(.{}, struct {
            fn work(c: *Context) void {
                const cause = c.wait(null);
                lib.debug.assert(cause != null);
                lib.debug.assert(cause.? == error.BrokenPipe);
            }
        }.work, .{&cc});

        lib.Thread.sleep(5_000_000);
        cc.cancelWithCause(error.BrokenPipe);
        t.join();

        const e = cc.err() orelse return error.MultiThreadCauseMissing;
        if (e != error.BrokenPipe) return error.MultiThreadCauseWrong;
    }

    {
        const bg = ctx_ns.background();
        var parent = try ctx_ns.withCancel(bg);
        defer parent.deinit();
        var child = try ctx_ns.withCancel(parent);
        defer child.deinit();

        const t = try lib.Thread.spawn(.{}, struct {
            fn work(c: *Context) void {
                const cause = c.wait(null);
                lib.debug.assert(cause != null);
                lib.debug.assert(cause.? == error.Canceled);
            }
        }.work, .{&child});

        lib.Thread.sleep(5_000_000);
        parent.cancel();
        t.join();

        const e = child.err() orelse return error.MultiThreadParentWakeMissing;
        if (e != error.Canceled) return error.MultiThreadParentWakeWrong;
    }

    {
        const Api = @TypeOf(ctx_ns);
        var threads: [6]lib.Thread = undefined;
        for (&threads) |*t| {
            t.* = try lib.Thread.spawn(.{}, struct {
                fn work(api: *const Api) void {
                    var i: usize = 0;
                    while (i < 200) : (i += 1) {
                        var ctx = api.withCancel(api.background()) catch unreachable;
                        ctx.deinit();
                    }
                }
            }.work, .{&ctx_ns});
        }
        for (threads) |t| t.join();
    }

    {
        const bg = ctx_ns.background();
        var parent = try ctx_ns.withDeadline(bg, lib.time.milliTimestamp() + 1000);
        var child = try ctx_ns.withDeadline(parent, lib.time.milliTimestamp() + 2000);
        defer child.deinit();

        const t = try lib.Thread.spawn(.{}, struct {
            fn work(c: *Context) void {
                var i: usize = 0;
                while (i < 10_000) : (i += 1) {
                    _ = c.deadline();
                }
            }
        }.work, .{&child});

        lib.Thread.sleep(1_000_000);
        parent.deinit();
        t.join();

        if (child.deadline() == null) return error.ReparentedChildShouldKeepDeadline;
        child.cancel();
    }

    log.info("multi-thread ok", .{});
}

fn FailingSpawnThreadType(comptime lib: type) type {
    return struct {
        pub const SpawnConfig = lib.Thread.SpawnConfig;
        pub const SpawnError = lib.Thread.SpawnError;
        pub const YieldError = lib.Thread.YieldError;
        pub const CpuCountError = lib.Thread.CpuCountError;
        pub const SetNameError = lib.Thread.SetNameError;
        pub const GetNameError = lib.Thread.GetNameError;
        pub const max_name_len = lib.Thread.max_name_len;
        pub const Id = lib.Thread.Id;
        pub const Mutex = lib.Thread.Mutex;
        pub const Condition = lib.Thread.Condition;
        pub const RwLock = lib.Thread.RwLock;

        const Self = @This();

        impl: u8 = 0,

        pub fn spawn(_: SpawnConfig, comptime _: anytype, _: anytype) SpawnError!Self {
            return error.SystemResources;
        }

        pub fn join(_: Self) void {}

        pub fn detach(_: Self) void {}

        pub fn yield() YieldError!void {
            return lib.Thread.yield();
        }

        pub fn sleep(ns: u64) void {
            lib.Thread.sleep(ns);
        }

        pub fn getCpuCount() CpuCountError!usize {
            return lib.Thread.getCpuCount();
        }

        pub fn getCurrentId() Id {
            return lib.Thread.getCurrentId();
        }

        pub fn setName(name: []const u8) SetNameError!void {
            return lib.Thread.setName(name);
        }

        pub fn getName(buf: *[max_name_len:0]u8) GetNameError!?[]const u8 {
            return lib.Thread.getName(buf);
        }
    };
}

fn CapturingSleepThreadType(comptime lib: type) type {
    return struct {
        pub const SpawnConfig = lib.Thread.SpawnConfig;
        pub const SpawnError = lib.Thread.SpawnError;
        pub const YieldError = lib.Thread.YieldError;
        pub const CpuCountError = lib.Thread.CpuCountError;
        pub const SetNameError = lib.Thread.SetNameError;
        pub const GetNameError = lib.Thread.GetNameError;
        pub const max_name_len = lib.Thread.max_name_len;
        pub const Id = lib.Thread.Id;
        pub const Mutex = lib.Thread.Mutex;
        pub const Condition = lib.Thread.Condition;
        pub const RwLock = lib.Thread.RwLock;

        const Self = @This();

        impl: lib.Thread = undefined,

        pub var sleep_calls: usize = 0;
        pub var last_sleep_ns: u64 = 0;

        pub fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) SpawnError!Self {
            return .{ .impl = try lib.Thread.spawn(config, f, args) };
        }

        pub fn join(self: Self) void {
            self.impl.join();
        }

        pub fn detach(self: Self) void {
            self.impl.detach();
        }

        pub fn yield() YieldError!void {
            return lib.Thread.yield();
        }

        pub fn sleep(ns: u64) void {
            sleep_calls += 1;
            last_sleep_ns = ns;
            lib.Thread.sleep(ns);
        }

        pub fn getCpuCount() CpuCountError!usize {
            return lib.Thread.getCpuCount();
        }

        pub fn getCurrentId() Id {
            return lib.Thread.getCurrentId();
        }

        pub fn setName(name: []const u8) SetNameError!void {
            return lib.Thread.setName(name);
        }

        pub fn getName(buf: *[max_name_len:0]u8) GetNameError!?[]const u8 {
            return lib.Thread.getName(buf);
        }
    };
}

fn CountingJoinThreadType(comptime lib: type) type {
    return struct {
        pub const SpawnConfig = lib.Thread.SpawnConfig;
        pub const SpawnError = lib.Thread.SpawnError;
        pub const YieldError = lib.Thread.YieldError;
        pub const CpuCountError = lib.Thread.CpuCountError;
        pub const SetNameError = lib.Thread.SetNameError;
        pub const GetNameError = lib.Thread.GetNameError;
        pub const max_name_len = lib.Thread.max_name_len;
        pub const Id = lib.Thread.Id;
        pub const Mutex = lib.Thread.Mutex;
        pub const Condition = lib.Thread.Condition;
        pub const RwLock = lib.Thread.RwLock;

        const Self = @This();

        impl: lib.Thread = undefined,

        pub var join_calls: usize = 0;

        pub fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) SpawnError!Self {
            return .{ .impl = try lib.Thread.spawn(config, f, args) };
        }

        pub fn join(self: Self) void {
            join_calls += 1;
            self.impl.join();
        }

        pub fn detach(self: Self) void {
            self.impl.detach();
        }

        pub fn yield() YieldError!void {
            return lib.Thread.yield();
        }

        pub fn sleep(ns: u64) void {
            lib.Thread.sleep(ns);
        }

        pub fn getCpuCount() CpuCountError!usize {
            return lib.Thread.getCpuCount();
        }

        pub fn getCurrentId() Id {
            return lib.Thread.getCurrentId();
        }

        pub fn setName(name: []const u8) SetNameError!void {
            return lib.Thread.setName(name);
        }

        pub fn getName(buf: *[max_name_len:0]u8) GetNameError!?[]const u8 {
            return lib.Thread.getName(buf);
        }
    };
}

test "std_compat" {
    const std = @import("std");
    try run(std);
}

test "root deinit with active child assert helper" {
    const std = @import("std");

    const helper_requested = blk: {
        const value = std.process.getEnvVarOwned(std.testing.allocator, root_deinit_assert_env) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk false,
            else => return err,
        };
        defer std.testing.allocator.free(value);
        break :blk std.mem.eql(u8, value, "1");
    };
    if (!helper_requested) return error.SkipZigTest;

    const CtxApi = root.Make(std);
    var ctx_ns = try CtxApi.init(std.testing.allocator);
    const bg = ctx_ns.background();
    _ = try ctx_ns.withCancel(bg);

    // This is the contract: deinitializing the API while the root still owns
    // live children must trip the debug assertion.
    ctx_ns.deinit();

    // If we ever reach here, the root deinit contract assertion did not fire.
    std.process.exit(root_deinit_missing_assert_exit_code);
}

test "root deinit with active child asserts" {
    const builtin = @import("builtin");
    const std = @import("std");

    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const exe_path = try std.fs.selfExePathAlloc(std.testing.allocator);
    defer std.testing.allocator.free(exe_path);

    var env_map = try std.process.getEnvMap(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put(root_deinit_assert_env, "1");

    const result = try std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{
            exe_path,
            "--test-filter",
            "root deinit with active child assert helper",
        },
        .env_map = &env_map,
        .max_output_bytes = 64 * 1024,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            try std.testing.expect(code != 0);
            try std.testing.expect(code != root_deinit_missing_assert_exit_code);
        },
        else => {},
    }
}
