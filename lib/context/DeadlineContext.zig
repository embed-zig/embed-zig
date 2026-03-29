//! DeadlineContext — context that auto-cancels when a deadline is reached.

const Context = @import("Context.zig");
const internal = @import("internal.zig");
const Allocator = @import("embed").mem.Allocator;

pub fn DeadlineContext(comptime lib: type) type {
    const Mutex = lib.Thread.Mutex;
    const Condition = lib.Thread.Condition;
    const RwLock = lib.Thread.RwLock;

    return struct {
        allocator: Allocator,
        tree: Context.TreeLink = .{},
        tree_rw: *RwLock,
        mu: Mutex = .{},
        cond: Condition = .{},
        cause: ?anyerror = null,
        deadline_ns: i128,
        timer_mu: Mutex = .{},
        timer_cond: Condition = .{},
        timer_canceled: bool = false,
        timer_thread: ?lib.Thread = null,
        timer_started: bool = false,

        const Self = @This();

        pub fn init(allocator: Allocator, parent: Context, deadline_ns: i128) Allocator.Error!Context {
            const self = try allocator.create(Self);
            const ctx = Context.init(self, &vtable, allocator);
            self.* = .{
                .allocator = allocator,
                .tree = .{
                    .ctx = ctx,
                    .parent = parent,
                },
                .tree_rw = internal.treeLock(parent, RwLock),
                .cause = parent.err(),
                .deadline_ns = deadline_ns,
            };

            if (self.cause == null) {
                if (self.effectiveDeadline() <= lib.time.nanoTimestamp()) {
                    self.cause = Context.DeadlineExceeded;
                } else {
                    internal.attachChild(parent, ctx);
                    self.ensureTimer();
                }
            }

            return ctx;
        }

        fn effectiveDeadline(self: *const Self) i128 {
            const self_mut: *Self = @constCast(self);
            self_mut.tree_rw.lockShared();
            defer self_mut.tree_rw.unlockShared();
            const parent = self_mut.tree.parent;
            if (parent) |p| {
                if (p.deadline()) |parent_dl| {
                    return @min(parent_dl, self.deadline_ns);
                }
            }
            return self.deadline_ns;
        }

        fn ensureTimer(self: *Self) void {
            if (self.timer_started) return;
            if (self.cause != null) return;
            self.timer_started = true;
            self.timer_thread = lib.Thread.spawn(.{}, timerFn, .{self}) catch |err| {
                self.markCanceled(err);
                return;
            };
        }

        fn timerFn(self: *Self) void {
            self.timer_mu.lock();
            while (!self.timer_canceled) {
                const remaining_ns = self.effectiveDeadline() - lib.time.nanoTimestamp();
                if (remaining_ns <= 0) break;

                const wait_ns: u64 = @intCast(@min(remaining_ns, @as(i128, @intCast((@as(u128, 1) << 64) - 1))));
                self.timer_cond.timedWait(&self.timer_mu, wait_ns) catch {};
            }
            const timer_canceled = self.timer_canceled;
            const deadline_reached = !timer_canceled and lib.time.nanoTimestamp() >= self.effectiveDeadline();
            self.timer_mu.unlock();

            if (!deadline_reached) return;

            self.mu.lock();
            const should_cancel = self.cause == null;
            self.mu.unlock();

            if (should_cancel) self.markCanceled(Context.DeadlineExceeded);
        }

        fn stopTimer(self: *Self) void {
            self.timer_mu.lock();
            self.timer_canceled = true;
            self.timer_mu.unlock();
            self.timer_cond.signal();

            if (self.timer_thread) |t| {
                t.join();
                self.timer_thread = null;
            }
        }

        fn markCanceled(self: *Self, cause: anyerror) void {
            self.mu.lock();
            if (self.cause != null) {
                self.mu.unlock();
                return;
            }
            self.cause = cause;
            self.mu.unlock();

            self.cond.broadcast();
            internal.cancelChildrenWithCause(self.tree.ctx, cause);
        }

        pub fn wait(self: *Self, timeout_ns: ?i64) ?anyerror {
            self.mu.lock();
            defer self.mu.unlock();

            if (timeout_ns) |ns| {
                const deadline_ns = lib.time.nanoTimestamp() + @as(i128, ns);
                while (self.cause == null) {
                    const remaining_ns = deadline_ns - lib.time.nanoTimestamp();
                    if (remaining_ns <= 0) return null;

                    self.cond.timedWait(&self.mu, @intCast(@min(remaining_ns, @as(i128, @intCast((@as(u128, 1) << 64) - 1))))) catch {};
                }
                return self.cause;
            }

            while (self.cause == null) {
                self.cond.wait(&self.mu);
            }
            return self.cause.?;
        }

        fn errImpl(ptr: *anyopaque) ?anyerror {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.mu.lock();
            defer self.mu.unlock();
            return self.cause;
        }

        fn deadlineImpl(ptr: *anyopaque) ?i128 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.effectiveDeadline();
        }

        fn valueImpl(ptr: *anyopaque, key: *const anyopaque) ?*const anyopaque {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            const parent = self.tree.parent orelse return null;
            return parent.vtable.valueFn(parent.ptr, key);
        }

        fn waitImpl(ptr: *anyopaque, timeout_ns: ?i64) ?anyerror {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.wait(timeout_ns);
        }

        fn cancelImpl(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.stopTimer();
            self.markCanceled(Context.Canceled);
        }

        fn cancelWithCauseImpl(ptr: *anyopaque, cause: anyerror) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.stopTimer();
            self.markCanceled(cause);
        }

        fn propagateCancelWithCauseImpl(ptr: *anyopaque, cause: anyerror) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.stopTimer();
            self.markCanceled(cause);
        }

        fn deinitImpl(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.stopTimer();
            internal.detachAndReparentChildren(self.tree.ctx);
            self.allocator.destroy(self);
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
            self.timer_cond.signal();
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

        pub const vtable: Context.VTable = .{
            .errFn = errImpl,
            .deadlineFn = deadlineImpl,
            .valueFn = valueImpl,
            .waitFn = waitImpl,
            .cancelFn = cancelImpl,
            .cancelWithCauseFn = cancelWithCauseImpl,
            .propagateCancelWithCauseFn = propagateCancelWithCauseImpl,
            .deinitFn = deinitImpl,
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
