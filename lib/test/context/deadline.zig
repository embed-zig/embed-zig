const embed = @import("embed");
const testing_mod = @import("testing");
const context_root = @import("context");
const Context = context_root.Context;
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            runImpl(lib, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_mod.TestRunner.make(Runner).new(&Holder.runner);
}

fn runImpl(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
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
        const RaceParent = test_utils.LockCancelParentType(lib);
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

    {
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

    {
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
