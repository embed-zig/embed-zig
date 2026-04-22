const stdz = @import("stdz");
const testing_mod = @import("testing");
const context_root = @import("context");
const Context = context_root.Context;

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("after_cancel_returns_cause", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try waitAfterCancelReturnsCauseCase(lib, case_allocator);
                }
            }.run));
            t.run("timeout_returns_null", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try waitTimeoutReturnsNullCase(lib, case_allocator);
                }
            }.run));
            t.run("spurious_wake_still_waits_full_timeout", testing_mod.TestRunner.fromFn(lib, 48 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try waitSpuriousWakeStillWaitsFullTimeoutCase(lib, case_allocator);
                }
            }.run));
            t.run("already_canceled_returns_existing_cause", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try waitAlreadyCanceledReturnsExistingCauseCase(lib, case_allocator);
                }
            }.run));
            t.run("value_context_wakes_on_parent_cancel", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try waitValueContextWakesOnParentCancelCase(lib, case_allocator);
                }
            }.run));
            t.run("value_context_timeout_does_not_call_parent_wait", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try waitValueContextTimeoutDoesNotCallParentWaitCase(lib, case_allocator);
                }
            }.run));
            t.run("deadline_context_returns_deadline_exceeded", testing_mod.TestRunner.fromFn(lib, 40 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try waitDeadlineContextReturnsDeadlineExceededCase(lib, case_allocator);
                }
            }.run));
            t.run("background_timeout_returns_null", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try waitBackgroundTimeoutReturnsNullCase(lib, case_allocator);
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

fn WaitForbiddenParentType(comptime lib: type) type {
    return struct {
        tree: Context.TreeLink = .{},
        tree_rw: lib.Thread.RwLock = .{},
        wait_called: bool = false,

        const Self = @This();

        fn context(self: *Self, allocator: lib.mem.Allocator) Context {
            const ctx = Context.init(self, &vtable, allocator);
            self.tree.ctx = ctx;
            return ctx;
        }

        fn errFn(_: *anyopaque) ?anyerror {
            return null;
        }

        fn errNoLockFn(_: *anyopaque) ?anyerror {
            return null;
        }

        fn deadlineFn(_: *anyopaque) ?i128 {
            return null;
        }

        fn deadlineNoLockFn(_: *anyopaque) ?i128 {
            return null;
        }

        fn valueFn(_: *anyopaque, _: *const anyopaque) ?*const anyopaque {
            return null;
        }

        fn valueNoLockFn(_: *anyopaque, _: *const anyopaque) ?*const anyopaque {
            return null;
        }

        fn waitFn(ptr: *anyopaque, _: ?i64) ?anyerror {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.wait_called = true;
            return error.Unexpected;
        }

        fn cancelFn(_: *anyopaque) void {}

        fn cancelWithCauseFn(_: *anyopaque, _: anyerror) void {}

        fn propagateCancelWithCauseFn(_: *anyopaque, _: anyerror) void {}

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
            self.tree_rw.lock();
        }

        fn unlockFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.unlock();
        }

        const vtable: Context.VTable = .{
            .errFn = errFn,
            .errNoLockFn = errNoLockFn,
            .deadlineFn = deadlineFn,
            .deadlineNoLockFn = deadlineNoLockFn,
            .valueFn = valueFn,
            .valueNoLockFn = valueNoLockFn,
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

fn waitAfterCancelReturnsCauseCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var ctx = try ctx_ns.withCancel(bg);
    defer ctx.deinit();
    ctx.cancel();
    const cause = ctx.wait(null) orelse return error.WaitAfterCancelShouldReturn;
    if (cause != error.Canceled) return error.WaitAfterCancelWrongCause;
}

fn waitTimeoutReturnsNullCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var ctx = try ctx_ns.withCancel(bg);
    defer ctx.deinit();
    if (ctx.wait(50 * lib.time.ns_per_ms) != null) return error.WaitTimeoutShouldReturnNull;
}

fn waitSpuriousWakeStillWaitsFullTimeoutCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

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

fn waitAlreadyCanceledReturnsExistingCauseCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var ctx = try ctx_ns.withCancel(bg);
    defer ctx.deinit();
    ctx.cancelWithCause(error.TimedOut);
    const cause = ctx.wait(50 * lib.time.ns_per_ms) orelse return error.WaitAlreadyCanceledMissing;
    if (cause != error.TimedOut) return error.WaitAlreadyCanceledWrongCause;
}

fn waitValueContextWakesOnParentCancelCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var key: Context.Key(u64) = .{};
    const bg = ctx_ns.background();
    var cc = try ctx_ns.withCancel(bg);
    defer cc.deinit();
    var ctx = try ctx_ns.withValue(u64, cc, &key, 42);
    defer ctx.deinit();

    const t = try lib.Thread.spawn(.{}, struct {
        fn work(c: *Context) void {
            const cause = c.wait(null);
            lib.debug.assert(cause != null);
            lib.debug.assert(cause.? == error.Canceled);
        }
    }.work, .{&ctx});

    lib.Thread.sleep(5 * lib.time.ns_per_ms);
    cc.cancel();
    t.join();

    const cause = ctx.err() orelse return error.WaitThroughValueMissing;
    if (cause != error.Canceled) return error.WaitThroughValueWrongCause;
}

fn waitValueContextTimeoutDoesNotCallParentWaitCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const Parent = WaitForbiddenParentType(lib);
    var parent_impl: Parent = .{};
    const parent = parent_impl.context(allocator);

    var key: Context.Key(u64) = .{};
    var ctx = try ctx_ns.withValue(u64, parent, &key, 42);
    defer ctx.deinit();

    if (ctx.wait(20 * lib.time.ns_per_ms) != null) return error.ValueWaitTimeoutShouldReturnNull;
    if (parent_impl.wait_called) return error.ValueWaitShouldNotCallParentWait;
}

fn waitDeadlineContextReturnsDeadlineExceededCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var ctx = try ctx_ns.withTimeout(bg, 100 * lib.time.ns_per_ms);
    defer ctx.deinit();
    const cause = ctx.wait(null) orelse return error.WaitDeadlineVtableMissing;
    if (cause != error.DeadlineExceeded) return error.WaitDeadlineVtableWrongCause;
}

fn waitBackgroundTimeoutReturnsNullCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    if (bg.wait(50 * lib.time.ns_per_ms) != null) return error.BackgroundWaitShouldReturnNull;
}
