//! Context test utilities — shared helpers and fake types for integration/context test runners.
const Context = @import("context").Context;

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

pub fn LockCancelParentType(comptime lib: type) type {
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

        fn errNoLockFn(ptr: *anyopaque) ?anyerror {
            return errFn(ptr);
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

pub fn ReparentableDeadlineParentType(comptime lib: type) type {
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

        fn errNoLockFn(ptr: *anyopaque) ?anyerror {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const parent = self.tree.parent orelse return null;
            return parent.vtable.errNoLockFn(parent.ptr);
        }

        fn errFn(ptr: *anyopaque) ?anyerror {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            return errNoLockFn(ptr);
        }

        fn deadlineNoLockFn(ptr: *anyopaque) ?i128 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const parent = self.tree.parent;
            if (parent) |p| {
                if (p.vtable.deadlineNoLockFn(p.ptr)) |parent_deadline| {
                    return @min(parent_deadline, self.deadline_ns);
                }
            }
            return self.deadline_ns;
        }

        fn deadlineFn(ptr: *anyopaque) ?i128 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            return deadlineNoLockFn(ptr);
        }

        fn valueNoLockFn(ptr: *anyopaque, key: *const anyopaque) ?*const anyopaque {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const parent = self.tree.parent orelse return null;
            return parent.vtable.valueNoLockFn(parent.ptr, key);
        }

        fn valueFn(ptr: *anyopaque, key: *const anyopaque) ?*const anyopaque {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            return valueNoLockFn(ptr, key);
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

pub fn ReparentGateThreadType(comptime lib: type) type {
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

pub fn FailingSpawnThreadType(comptime lib: type) type {
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

pub fn CapturingSleepThreadType(comptime lib: type) type {
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

pub fn CountingJoinThreadType(comptime lib: type) type {
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
