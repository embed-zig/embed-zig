//! ValueContext — attaches a typed key-value pair to the context chain.
//!
//! Preserves the parent-linked value lookup chain and does not expose public
//! cancellation of its own. Parent cancellation still propagates through the
//! value node, is cached locally so err()/wait() stay stable after reparenting,
//! and continues onward to descendants. Deadline lookup still delegates to the
//! parent chain.
//!
//! Usage:
//!   const request_id_key: Context.Key(u64) = .{};
//!   var ctx = try make(std, time, u64).init(allocator, parent, &request_id_key, 42);
//!   defer ctx.deinit();
//!   const id = ctx.value(u64, &request_id_key);  // returns 42

const stdz = @import("stdz");
const time_mod = @import("time");
const Allocator = stdz.mem.Allocator;

const Context = @import("Context.zig");
const internal = @import("internal.zig");

pub fn make(comptime std: type, comptime time: type, comptime T: type) type {
    const Mutex = std.Thread.Mutex;
    const Condition = std.Thread.Condition;
    const RwLock = std.Thread.RwLock;

    return struct {
        allocator: Allocator,
        tree: Context.TreeLink = .{},
        tree_rw: *RwLock,
        mu: Mutex = .{},
        cond: Condition = .{},
        cause: ?anyerror = null,
        key: *const anyopaque,
        val_storage: T,

        const Self = @This();

        pub fn init(allocator: Allocator, parent: Context, key: *const Context.Key(T), val: T) Allocator.Error!Context {
            const self = try allocator.create(Self);
            const ctx = Context.init(self, &vtable, allocator);
            self.* = .{
                .allocator = allocator,
                .tree = .{
                    .ctx = ctx,
                    .parent = parent,
                },
                .tree_rw = internal.treeLock(parent, RwLock),
                .key = @ptrCast(key),
                .val_storage = val,
            };
            internal.attachChild(parent, ctx);
            if (parent.err()) |cause| {
                self.markCanceled(cause);
            }
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

            self.cond.broadcast();
            internal.cancelChildrenWithCause(self.tree.ctx, cause);
        }

        fn errNoLockImpl(ptr: *anyopaque) ?anyerror {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.mu.lock();
            defer self.mu.unlock();
            if (self.cause) |cause| return cause;
            const parent = self.tree.parent orelse return null;
            return internal.errNoLock(parent);
        }

        fn errImpl(ptr: *anyopaque) ?anyerror {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            return errNoLockImpl(ptr);
        }

        fn deadlineNoLockImpl(ptr: *anyopaque) ?time_mod.instant.Time {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const parent = self.tree.parent orelse return null;
            return internal.deadlineNoLock(parent);
        }

        fn deadlineImpl(ptr: *anyopaque) ?time_mod.instant.Time {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            return deadlineNoLockImpl(ptr);
        }

        fn valueNoLockImpl(ptr: *anyopaque, key: *const anyopaque) ?*const anyopaque {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (key == self.key) {
                return @ptrCast(&self.val_storage);
            }
            const parent = self.tree.parent orelse return null;
            return internal.valueNoLock(parent, key);
        }

        fn valueImpl(ptr: *anyopaque, key: *const anyopaque) ?*const anyopaque {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            return valueNoLockImpl(ptr, key);
        }

        pub fn wait(self: *Self, timeout: ?time_mod.duration.Duration) ?anyerror {
            self.mu.lock();
            defer self.mu.unlock();

            if (timeout) |duration| {
                if (duration <= 0) return null;
                const deadline = internal.timeoutDeadline(time, duration);
                while (self.cause == null) {
                    const timed_wait = internal.remainingTimedWait(deadline, time.instant.now()) orelse return null;

                    self.cond.timedWait(&self.mu, timed_wait) catch {};
                }
                return self.cause;
            }

            while (self.cause == null) {
                self.cond.wait(&self.mu);
            }
            return self.cause.?;
        }

        fn waitImpl(ptr: *anyopaque, timeout: ?time_mod.duration.Duration) ?anyerror {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.wait(timeout);
        }

        fn cancelImpl(ptr: *anyopaque) void {
            _ = ptr;
        }

        fn cancelWithCauseImpl(_: *anyopaque, _: anyerror) void {}

        fn propagateCancelWithCauseImpl(ptr: *anyopaque, cause: anyerror) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            self.markCanceled(cause);
        }

        fn deinitImpl(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
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
            .errNoLockFn = errNoLockImpl,
            .deadlineFn = deadlineImpl,
            .deadlineNoLockFn = deadlineNoLockImpl,
            .valueFn = valueImpl,
            .valueNoLockFn = valueNoLockImpl,
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
