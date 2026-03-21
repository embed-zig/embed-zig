//! ValueContext — attaches a typed key-value pair to the context chain.
//!
//! Delegates err() / deadline() / wait() to parent and adds one layer to the
//! value lookup chain. `cancel()` / `cancelWithCause()` are no-ops for the
//! value node itself; it does not add its own cancellation state.
//!
//! Usage:
//!   const request_id_key: Context.Key(u64) = .{};
//!   var ctx = try ValueContext(lib, u64).init(allocator, parent, &request_id_key, 42);
//!   defer ctx.deinit();
//!   const id = ctx.value(u64, &request_id_key);  // returns 42

const Context = @import("Context.zig");
const internal = @import("internal.zig");
const Allocator = @import("embed").mem.Allocator;

pub fn ValueContext(comptime lib: type, comptime T: type) type {
    const RwLock = lib.Thread.RwLock;

    return struct {
        allocator: Allocator,
        tree: Context.TreeLink = .{},
        tree_rw: *RwLock,
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
            return ctx;
        }

        fn errImpl(ptr: *anyopaque) ?anyerror {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            const parent = self.tree.parent orelse return null;
            return parent.err();
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
            if (key == self.key) {
                return @ptrCast(&self.val_storage);
            }
            self.tree_rw.lockShared();
            defer self.tree_rw.unlockShared();
            const parent = self.tree.parent orelse return null;
            return parent.vtable.valueFn(parent.ptr, key);
        }

        fn waitImpl(ptr: *anyopaque, timeout_ms: ?u32) ?anyerror {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const deadline_ms: ?i64 = if (timeout_ms) |ms| lib.time.milliTimestamp() + @as(i64, ms) else null;

            while (true) {
                const slice_ms: u32 = blk: {
                    if (deadline_ms) |deadline| {
                        const remaining_ms = deadline - lib.time.milliTimestamp();
                        if (remaining_ms <= 0) return null;
                        break :blk @intCast(@min(remaining_ms, 10));
                    }
                    break :blk 10;
                };

                self.tree_rw.lockShared();
                const parent = self.tree.parent orelse {
                    self.tree_rw.unlockShared();
                    return null;
                };
                const cause = parent.wait(slice_ms);
                self.tree_rw.unlockShared();
                if (cause) |err| return err;
            }
        }

        fn cancelImpl(ptr: *anyopaque) void {
            _ = ptr;
        }

        fn cancelWithCauseImpl(_: *anyopaque, _: anyerror) void {}

        fn propagateCancelWithCauseImpl(ptr: *anyopaque, cause: anyerror) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            internal.cancelChildrenWithCause(self.tree.ctx, cause);
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
