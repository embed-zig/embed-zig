//! CancelContext — cancelable context node with recursive propagation.

const Context = @import("Context.zig");
const internal = @import("internal.zig");
const Allocator = @import("embed").mem.Allocator;

pub fn CancelContext(comptime lib: type) type {
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

        const Self = @This();

        pub fn init(allocator: Allocator, parent: Context) Allocator.Error!Context {
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
            };
            if (self.cause == null) {
                internal.attachChild(parent, ctx);
            }
            return ctx;
        }

        pub fn cancelWithCause(self: *Self, cause: anyerror) void {
            self.markCanceled(cause);
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

        pub fn wait(self: *Self, timeout_ms: ?u32) ?anyerror {
            self.mu.lock();
            defer self.mu.unlock();

            if (timeout_ms) |ms| {
                const deadline_ms = lib.time.milliTimestamp() + @as(i64, ms);
                while (self.cause == null) {
                    const remaining_ms = deadline_ms - lib.time.milliTimestamp();
                    if (remaining_ms <= 0) return null;

                    const remaining_ns = @as(u64, @intCast(remaining_ms)) * lib.time.ns_per_ms;
                    self.cond.timedWait(&self.mu, remaining_ns) catch {};
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

        fn deadlineImpl(ptr: *anyopaque) ?i64 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            const parent = self.tree.parent orelse return null;
            return parent.deadline();
        }

        fn valueImpl(ptr: *anyopaque, key: *const anyopaque) ?*const anyopaque {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            const parent = self.tree.parent orelse return null;
            return parent.vtable.valueFn(parent.ptr, key);
        }

        fn waitImpl(ptr: *anyopaque, timeout_ms: ?u32) ?anyerror {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.wait(timeout_ms);
        }

        fn cancelImpl(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.markCanceled(Context.Canceled);
        }

        fn cancelWithCauseImpl(ptr: *anyopaque, cause: anyerror) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.markCanceled(cause);
        }

        fn propagateCancelWithCauseImpl(ptr: *anyopaque, cause: anyerror) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
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
