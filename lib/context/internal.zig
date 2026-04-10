const Context = @import("Context.zig");

pub fn tree(ctx: Context) *Context.TreeLink {
    return ctx.vtable.treeFn(ctx.ptr);
}

pub fn treeLock(ctx: Context, comptime RwLock: type) *RwLock {
    return @ptrCast(@alignCast(ctx.vtable.treeLockFn(ctx.ptr)));
}

pub fn lock(ctx: Context) void {
    ctx.vtable.lockFn(ctx.ptr);
}

// Caller already holds the shared root tree lock.
pub fn errNoLock(ctx: Context) ?anyerror {
    return ctx.vtable.errNoLockFn(ctx.ptr);
}

// Caller already holds the shared root tree lock.
pub fn deadlineNoLock(ctx: Context) ?i128 {
    return ctx.vtable.deadlineNoLockFn(ctx.ptr);
}

// Caller already holds the shared root tree lock.
pub fn valueNoLock(ctx: Context, key: *const anyopaque) ?*const anyopaque {
    return ctx.vtable.valueNoLockFn(ctx.ptr, key);
}

pub fn lockShared(ctx: Context) void {
    ctx.vtable.lockSharedFn(ctx.ptr);
}

pub fn unlock(ctx: Context) void {
    ctx.vtable.unlockFn(ctx.ptr);
}

pub fn unlockShared(ctx: Context) void {
    ctx.vtable.unlockSharedFn(ctx.ptr);
}

pub fn reparent(ctx: Context, parent: ?Context) void {
    ctx.vtable.reparentFn(ctx.ptr, parent);
}

pub fn attachChild(parent: Context, child: Context) void {
    lock(parent);
    defer unlock(parent);

    reparent(child, parent);
    tree(parent).children.append(&tree(child).node);
}

pub fn cancelChildren(ctx: Context) void {
    cancelChildrenWithCause(ctx, Context.Canceled);
}

// Recursive cancellation walks can stack shared-lock acquisitions on the same
// root lock, so the injected RwLock must tolerate nested shared readers.
pub fn cancelChildrenWithCause(ctx: Context, cause: anyerror) void {
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

pub fn detachAndReparentChildren(ctx: Context) void {
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
