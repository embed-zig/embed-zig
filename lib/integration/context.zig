//! Context test runner — exercises cancel propagation, value passing, deadlines, and wait.
//!
//! Accepts any type with the same shape as std (lib.Thread, lib.time, etc.).
//! The public entrypoint is `make(lib)`, which returns a `testing.TestRunner`.
//!
//! Usage:
//!   const runner = @import("integration/context.zig").make(lib);
//!   t.run("context", runner);

const embed = @import("embed");
const testing_mod = @import("testing");
const root = @import("context");
const Context = root.Context;

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = t;
            runImpl(lib, allocator) catch return false;
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

fn runImpl(comptime lib: type, allocator: lib.mem.Allocator) !void {
    try runCase(lib, allocator, backgroundTests);
    try runCase(lib, allocator, cancelBasicTests);
    try runCase(lib, allocator, cancelCauseTests);
    try runCase(lib, allocator, cancelPropagationTests);
    try runCase(lib, allocator, valueTests);
    try runCase(lib, allocator, lifecycleTests);
    try runCase(lib, allocator, deadlineTests);
    try runCase(lib, allocator, waitTests);
    try runCase(lib, allocator, multiThreadTests);
}

fn runCase(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    comptime CaseFn: fn (type, lib.mem.Allocator) anyerror!void,
) !void {
    try CaseFn(lib, allocator);
}

fn tree(ctx: Context) *Context.TreeLink {
    return ctx.vtable.treeFn(ctx.ptr);
}

fn treeLock(ctx: Context, comptime RwLock: type) *RwLock {
    return @ptrCast(@alignCast(ctx.vtable.treeLockFn(ctx.ptr)));
}

fn lock(ctx: Context) void {
    ctx.vtable.lockFn(ctx.ptr);
}

fn unlock(ctx: Context) void {
    ctx.vtable.unlockFn(ctx.ptr);
}

fn lockShared(ctx: Context) void {
    ctx.vtable.lockSharedFn(ctx.ptr);
}

fn unlockShared(ctx: Context) void {
    ctx.vtable.unlockSharedFn(ctx.ptr);
}

fn reparent(ctx: Context, parent: ?Context) void {
    ctx.vtable.reparentFn(ctx.ptr, parent);
}

fn attachChildForTest(parent: Context, child: Context) void {
    lock(parent);
    defer unlock(parent);

    reparent(child, parent);
    tree(parent).children.append(&tree(child).node);
}

fn cancelChildrenWithCauseForTest(ctx: Context, cause: anyerror) void {
    lockShared(ctx);
    defer unlockShared(ctx);

    var it = tree(ctx).children.first;
    while (it) |n| {
        const next = n.next;
        const child = Context.TreeLink.fromNode(n).ctx;
        child.vtable.propagateCancelWithCauseFn(child.ptr, cause);
        it = next;
    }
}

fn detachAndReparentChildrenForTest(ctx: Context) void {
    lock(ctx);
    defer unlock(ctx);
    const parent = tree(ctx).parent;

    if (parent) |p| {
        tree(p).children.remove(&tree(ctx).node);
    }

    while (tree(ctx).children.first) |n| {
        tree(ctx).children.remove(n);
        const child = Context.TreeLink.fromNode(n).ctx;
        reparent(child, parent);
        if (parent) |p| {
            tree(p).children.append(n);
        }
    }

    reparent(ctx, null);
}
// ---------------------------------------------------------------------------
// Background
// ---------------------------------------------------------------------------

fn backgroundTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
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
        const FakeCtxApi = root.make(FakeLib);
        var fake_ctx_ns = try FakeCtxApi.init(allocator);
        defer fake_ctx_ns.deinit();

        CapturingThread.sleep_calls = 0;
        CapturingThread.last_sleep_ns = 0;
        if (fake_ctx_ns.background().wait(5 * lib.time.ns_per_ms) != null) return error.BackgroundWaitShouldReturnNull;
        if (CapturingThread.sleep_calls == 0) return error.BackgroundWaitShouldUseLibThreadSleep;
        if (CapturingThread.last_sleep_ns != 5 * lib.time.ns_per_ms) return error.BackgroundWaitWrongSleepDuration;
    }
}

// ---------------------------------------------------------------------------
// Cancel: basic
// ---------------------------------------------------------------------------

fn cancelBasicTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
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
}

// ---------------------------------------------------------------------------
// Cancel: cause
// ---------------------------------------------------------------------------

fn cancelCauseTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
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
}

// ---------------------------------------------------------------------------
// Cancel: propagation
// ---------------------------------------------------------------------------

fn cancelPropagationTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
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

    {
        const RaceParent = LockCancelParentType(lib);
        var parent_impl: RaceParent = .{};
        const parent = parent_impl.context(allocator);
        parent_impl.cancel_on_next_lock = true;

        var child = try ctx_ns.withCancel(parent);
        defer child.deinit();

        const e = child.err() orelse return error.ChildInitShouldObserveParentCancelDuringAttach;
        if (e != error.BrokenPipe) return error.ChildInitParentCancelDuringAttachWrongCause;
    }
}

// ---------------------------------------------------------------------------
// Value
// ---------------------------------------------------------------------------

fn valueTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
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
}

// ---------------------------------------------------------------------------
// Lifecycle / ownership
// ---------------------------------------------------------------------------

fn lifecycleTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const CtxApi = root.make(lib);

    {
        var ctx_ns = try CtxApi.init(allocator);
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
        var ctx_ns = try CtxApi.init(allocator);
        const bg = ctx_ns.background();
        var parent = try ctx_ns.withCancel(bg);
        var child = try ctx_ns.withCancel(parent);

        parent.deinit();
        try testing.expect(ctx_ns.shared.background_impl.tree.children.first != null);

        child.deinit();
        try testing.expect(ctx_ns.shared.background_impl.tree.children.first == null);

        ctx_ns.deinit();
    }
}

// ---------------------------------------------------------------------------
// Deadline / Timeout
// ---------------------------------------------------------------------------

fn deadlineTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    {
        const bg = ctx_ns.background();
        const dl = lib.time.nanoTimestamp() + 10000 * lib.time.ns_per_ms;
        var dc = try ctx_ns.withDeadline(bg, dl);
        defer dc.deinit();
        const got = dc.deadline() orelse return error.DeadlineMissing;
        if (got != dl) return error.DeadlineWrongValue;
    }

    {
        const bg = ctx_ns.background();
        const past = lib.time.nanoTimestamp() - 1000 * lib.time.ns_per_ms;
        var dc = try ctx_ns.withDeadline(bg, past);
        defer dc.deinit();
        const e = dc.err() orelse return error.ExpiredDeadlineShouldCancel;
        if (e != error.DeadlineExceeded) return error.ExpiredDeadlineWrongCause;
    }

    {
        const bg = ctx_ns.background();
        var dc = try ctx_ns.withTimeout(bg, 100 * lib.time.ns_per_ms);
        defer dc.deinit();
        if (dc.err() != null) return error.TimeoutShouldStartActive;
        const cause = dc.wait(null) orelse return error.TimeoutWaitShouldReturnCause;
        if (cause != error.DeadlineExceeded) return error.TimeoutWaitWrongCause;
    }

    {
        const bg = ctx_ns.background();
        var dc = try ctx_ns.withDeadline(bg, lib.time.nanoTimestamp() + 60000 * lib.time.ns_per_ms);
        defer dc.deinit();
        dc.cancel();
        const e = dc.err() orelse return error.ManualCancelDeadlineMissing;
        if (e != error.Canceled) return error.ManualCancelDeadlineWrongCause;
    }

    {
        const bg = ctx_ns.background();
        const dl = lib.time.nanoTimestamp() + 10000 * lib.time.ns_per_ms;
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
        var dc = try ctx_ns.withDeadline(parent, lib.time.nanoTimestamp() + 60000 * lib.time.ns_per_ms);
        defer dc.deinit();
        if (dc.err() != null) return error.DeadlineChildShouldStartActive;
        parent.cancel();
        const e = dc.err() orelse return error.ParentCancelShouldPropagateToDeadline;
        if (e != error.Canceled) return error.ParentCancelDeadlineWrongCause;
    }

    {
        const bg = ctx_ns.background();
        var parent = try ctx_ns.withDeadline(bg, lib.time.nanoTimestamp() + 1 * lib.time.ns_per_ms);
        defer parent.deinit();
        lib.Thread.sleep(5 * lib.time.ns_per_ms);

        var child = try ctx_ns.withDeadline(parent, lib.time.nanoTimestamp() + 60000 * lib.time.ns_per_ms);
        defer child.deinit();
        const e = child.err() orelse return error.ChildOfElapsedParentDeadlineShouldStartCanceled;
        if (e != error.DeadlineExceeded) return error.ChildOfElapsedParentDeadlineWrongCause;
    }

    {
        const RaceParent = LockCancelParentType(lib);
        var parent_impl: RaceParent = .{};
        const parent = parent_impl.context(allocator);
        parent_impl.cancel_on_next_lock = true;

        var child = try ctx_ns.withDeadline(parent, lib.time.nanoTimestamp() + 1000 * lib.time.ns_per_ms);
        defer child.deinit();

        const e = child.err() orelse return error.DeadlineInitShouldObserveParentCancelDuringAttach;
        if (e != error.BrokenPipe) return error.DeadlineInitParentCancelDuringAttachWrongCause;
    }

    {
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

    {
        const FailingThread = FailingSpawnThreadType(lib);
        const FakeLib = struct {
            pub const Thread = FailingThread;
            pub const time = lib.time;
            pub const mem = lib.mem;
            pub const DoublyLinkedList = lib.DoublyLinkedList;
        };
        const FakeCtxApi = root.make(FakeLib);
        var fake_ctx_ns = try FakeCtxApi.init(allocator);
        defer fake_ctx_ns.deinit();

        const bg = fake_ctx_ns.background();
        var dc = try fake_ctx_ns.withTimeout(bg, 1000 * lib.time.ns_per_ms);
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
        const FakeCtxApi = root.make(FakeLib);
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

    {
        const ReparentThread = ReparentGateThreadType(lib);
        const FakeLib = struct {
            pub const Thread = ReparentThread;
            pub const time = lib.time;
            pub const mem = lib.mem;
            pub const DoublyLinkedList = lib.DoublyLinkedList;
        };
        const FakeCtxApi = root.make(FakeLib);
        var fake_ctx_ns = try FakeCtxApi.init(allocator);
        defer fake_ctx_ns.deinit();

        ReparentThread.Condition.resetHooks();
        defer ReparentThread.Condition.resetHooks();

        const bg = fake_ctx_ns.background();
        const ReparentableDeadlineParent = ReparentableDeadlineParentType(FakeLib);
        var parent_impl: ReparentableDeadlineParent = .{};
        var parent = parent_impl.context(allocator, bg, lib.time.nanoTimestamp() + 80 * lib.time.ns_per_ms);
        ReparentThread.Condition.armTimedWaitHook();
        var child = try fake_ctx_ns.withDeadline(parent, lib.time.nanoTimestamp() + 250 * lib.time.ns_per_ms);
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
        if (child.err() != null) return error.ReparentedDeadlineChildShouldNotUseOldDeadline;

        child.cancel();
    }
}

// ---------------------------------------------------------------------------
// Wait (via Context VTable)
// ---------------------------------------------------------------------------

fn waitTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
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
        if (ctx.wait(50 * lib.time.ns_per_ms) != null) return error.WaitTimeoutShouldReturnNull;
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

        if (ctx.wait(40 * lib.time.ns_per_ms) != null) return error.WaitSpuriousWakeShouldReturnNull;
        if (timer.read() < 20 * lib.time.ns_per_ms) return error.WaitReturnedTooEarlyAfterSpuriousWake;
    }

    {
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withCancel(bg);
        defer ctx.deinit();
        ctx.cancelWithCause(error.TimedOut);
        const cause = ctx.wait(50 * lib.time.ns_per_ms) orelse return error.WaitAlreadyCanceledMissing;
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
        const cause = ctx.wait(100 * lib.time.ns_per_ms) orelse return error.WaitThroughValueMissing;
        if (cause != error.Canceled) return error.WaitThroughValueWrongCause;
    }

    {
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withTimeout(bg, 100 * lib.time.ns_per_ms);
        defer ctx.deinit();
        const cause = ctx.wait(null) orelse return error.WaitDeadlineVtableMissing;
        if (cause != error.DeadlineExceeded) return error.WaitDeadlineVtableWrongCause;
    }

    {
        const bg = ctx_ns.background();
        if (bg.wait(50 * lib.time.ns_per_ms) != null) return error.BackgroundWaitShouldReturnNull;
    }
}

// ---------------------------------------------------------------------------
// Multi-thread
// ---------------------------------------------------------------------------

fn multiThreadTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
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
        var parent = try ctx_ns.withDeadline(bg, lib.time.nanoTimestamp() + 1000 * lib.time.ns_per_ms);
        var child = try ctx_ns.withDeadline(parent, lib.time.nanoTimestamp() + 2000 * lib.time.ns_per_ms);
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
}

fn LockCancelParentType(comptime lib: type) type {
    return struct {
        tree: Context.TreeLink = .{},
        tree_rw: lib.Thread.RwLock = .{},
        mu: lib.Thread.Mutex = .{},
        cause: ?anyerror = null,
        cancel_on_next_lock: bool = false,

        const Self = @This();

        pub fn context(self: *Self, allocator: lib.mem.Allocator) Context {
            const ctx = Context.init(self, &vtable, allocator);
            self.tree.ctx = ctx;
            return ctx;
        }

        fn markCanceled(self: *Self, cause: anyerror) void {
            self.mu.lock();
            if (self.cause != null) {
                self.mu.unlock();
                return;
            }
            self.cause = cause;
            self.mu.unlock();

            cancelChildrenWithCauseForTest(self.tree.ctx, cause);
        }

        fn errFn(ptr: *anyopaque) ?anyerror {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.mu.lock();
            defer self.mu.unlock();
            return self.cause;
        }

        fn deadlineFn(_: *anyopaque) ?i128 {
            return null;
        }

        fn valueFn(_: *anyopaque, _: *const anyopaque) ?*const anyopaque {
            return null;
        }

        fn waitFn(ptr: *anyopaque, _: ?i64) ?anyerror {
            return errFn(ptr);
        }

        fn cancelFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.markCanceled(error.Canceled);
        }

        fn cancelWithCauseFn(ptr: *anyopaque, cause: anyerror) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.markCanceled(cause);
        }

        fn propagateCancelWithCauseFn(ptr: *anyopaque, cause: anyerror) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.markCanceled(cause);
        }

        fn deinitFn(_: *anyopaque) void {}

        fn treeFn(ptr: *anyopaque) *Context.TreeLink {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return &self.tree;
        }

        fn treeLockFn(ptr: *anyopaque) *anyopaque {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return @ptrCast(&self.tree_rw);
        }

        fn reparentFn(_: *anyopaque, _: ?Context) void {}

        fn lockSharedFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
        }

        fn unlockSharedFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.unlockShared();
        }

        fn lockFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.cancel_on_next_lock) {
                self.cancel_on_next_lock = false;
                self.markCanceled(error.BrokenPipe);
            }
            self.tree_rw.lock();
        }

        fn unlockFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.unlock();
        }

        const vtable: Context.VTable = .{
            .errFn = errFn,
            .deadlineFn = deadlineFn,
            .valueFn = valueFn,
            .waitFn = waitFn,
            .cancelFn = cancelFn,
            .cancelWithCauseFn = cancelWithCauseFn,
            .propagateCancelWithCauseFn = propagateCancelWithCauseFn,
            .deinitFn = deinitFn,
            .treeFn = treeFn,
            .treeLockFn = treeLockFn,
            .reparentFn = reparentFn,
            .lockSharedFn = lockSharedFn,
            .unlockSharedFn = unlockSharedFn,
            .lockFn = lockFn,
            .unlockFn = unlockFn,
        };
    };
}

fn ReparentableDeadlineParentType(comptime lib: type) type {
    return struct {
        tree: Context.TreeLink = .{},
        tree_rw: *lib.Thread.RwLock = undefined,
        deadline_ns: i128 = 0,

        const Self = @This();

        pub fn context(self: *Self, allocator: lib.mem.Allocator, parent: Context, deadline_ns: i128) Context {
            const ctx = Context.init(self, &vtable, allocator);
            self.* = .{
                .tree = .{
                    .ctx = ctx,
                    .parent = parent,
                },
                .tree_rw = treeLock(parent, lib.Thread.RwLock),
                .deadline_ns = deadline_ns,
            };
            attachChildForTest(parent, ctx);
            return ctx;
        }

        fn errFn(ptr: *anyopaque) ?anyerror {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            const parent = self.tree.parent orelse return null;
            return parent.err();
        }

        fn deadlineFn(ptr: *anyopaque) ?i128 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            const parent = self.tree.parent;
            if (parent) |p| {
                if (p.deadline()) |parent_deadline| {
                    return @min(parent_deadline, self.deadline_ns);
                }
            }
            return self.deadline_ns;
        }

        fn valueFn(ptr: *anyopaque, key: *const anyopaque) ?*const anyopaque {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            const parent = self.tree.parent orelse return null;
            return parent.vtable.valueFn(parent.ptr, key);
        }

        fn waitFn(ptr: *anyopaque, _: ?i64) ?anyerror {
            return errFn(ptr);
        }

        fn cancelFn(_: *anyopaque) void {}

        fn cancelWithCauseFn(_: *anyopaque, _: anyerror) void {}

        fn propagateCancelWithCauseFn(_: *anyopaque, _: anyerror) void {}

        fn deinitFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            detachAndReparentChildrenForTest(self.tree.ctx);
        }

        fn treeFn(ptr: *anyopaque) *Context.TreeLink {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return &self.tree;
        }

        fn treeLockFn(ptr: *anyopaque) *anyopaque {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return @ptrCast(self.tree_rw);
        }

        fn reparentFn(ptr: *anyopaque, parent: ?Context) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree.parent = parent;
        }

        fn lockSharedFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
        }

        fn unlockSharedFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.unlockShared();
        }

        fn lockFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lock();
        }

        fn unlockFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.unlock();
        }

        const vtable: Context.VTable = .{
            .errFn = errFn,
            .deadlineFn = deadlineFn,
            .valueFn = valueFn,
            .waitFn = waitFn,
            .cancelFn = cancelFn,
            .cancelWithCauseFn = cancelWithCauseFn,
            .propagateCancelWithCauseFn = propagateCancelWithCauseFn,
            .deinitFn = deinitFn,
            .treeFn = treeFn,
            .treeLockFn = treeLockFn,
            .reparentFn = reparentFn,
            .lockSharedFn = lockSharedFn,
            .unlockSharedFn = unlockSharedFn,
            .lockFn = lockFn,
            .unlockFn = unlockFn,
        };
    };
}

fn ReparentGateThreadType(comptime lib: type) type {
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
        pub const RwLock = lib.Thread.RwLock;
        pub const Condition = struct {
            impl: lib.Thread.Condition = .{},

            const ConditionSelf = @This();

            pub var intercept_next_timed_wait: bool = false;
            pub var timed_wait_intercepted: bool = false;
            pub var release_wait: bool = false;
            pub var gate_mu: lib.Thread.Mutex = .{};
            pub var gate_cond: lib.Thread.Condition = .{};

            pub fn armTimedWaitHook() void {
                gate_mu.lock();
                intercept_next_timed_wait = true;
                timed_wait_intercepted = false;
                release_wait = false;
                gate_mu.unlock();
            }

            pub fn waitForTimedWaitHook() void {
                gate_mu.lock();
                defer gate_mu.unlock();
                while (!timed_wait_intercepted) {
                    gate_cond.wait(&gate_mu);
                }
            }

            pub fn releaseTimedWaitHook() void {
                gate_mu.lock();
                release_wait = true;
                gate_mu.unlock();
                gate_cond.broadcast();
            }

            pub fn resetHooks() void {
                gate_mu.lock();
                intercept_next_timed_wait = false;
                timed_wait_intercepted = false;
                release_wait = false;
                gate_mu.unlock();
            }

            pub fn wait(self: *ConditionSelf, mu: *Mutex) void {
                self.impl.wait(mu);
            }

            pub fn timedWait(self: *ConditionSelf, mu: *Mutex, ns: u64) anyerror!void {
                if (intercept_next_timed_wait) {
                    gate_mu.lock();
                    intercept_next_timed_wait = false;
                    timed_wait_intercepted = true;
                    gate_cond.broadcast();
                    while (!release_wait) {
                        gate_cond.wait(&gate_mu);
                    }
                    gate_mu.unlock();
                }
                try self.impl.timedWait(mu, ns);
            }

            pub fn signal(self: *ConditionSelf) void {
                self.impl.signal();
            }

            pub fn broadcast(self: *ConditionSelf) void {
                self.impl.broadcast();
            }
        };

        const Self = @This();

        impl: lib.Thread = undefined,

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
