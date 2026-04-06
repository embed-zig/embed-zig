//! context — Go-style context for cancellation propagation and value passing.
//!
//! Supports cancel-with-cause (like Go's WithCancelCause), deadline, and
//! timeout. The default cancel() uses error.Canceled; withDeadline uses
//! error.DeadlineExceeded.
//!
//! Usage:
//!   const Context = @import("context").make(lib);
//!   var context = try Context.init(allocator);
//!   defer context.deinit();
//!
//!   const request_id_key: context.Context.Key(u64) = .{};
//!
//!   const bg = context.background();
//!   var cancel_ctx = try context.withCancel(bg);
//!   defer cancel_ctx.deinit();
//!
//!   var ctx = try context.withValue(u64, cancel_ctx, &request_id_key, 42);
//!   defer ctx.deinit();
//!
//!   // Cancel with default error.Canceled:
//!   cancel_ctx.cancel();
//!
//!   // Or cancel with a specific cause:
//!   cancel_ctx.cancelWithCause(error.BrokenPipe);
//!
//!   // Deadline (absolute nanoTimestamp):
//!   var dc = try context.withDeadline(bg, lib.time.nanoTimestamp() + 5 * lib.time.ns_per_ms);
//!   defer dc.deinit();
//!
//!   // Timeout (relative nanoseconds):
//!   var tc = try context.withTimeout(bg, 5 * lib.time.ns_per_ms);
//!   defer tc.deinit();

const embed = @import("embed");
pub const Context = @import("context/Context.zig");
const cancel_context = @import("context/CancelContext.zig");
const deadline_context = @import("context/DeadlineContext.zig");
const value_context = @import("context/ValueContext.zig");

pub fn make(comptime lib: type) type {
    const Background = struct {
        tree: Context.TreeLink = .{},
        tree_rw: lib.Thread.RwLock = .{},

        const Self = @This();

        fn errFn(_: *anyopaque) ?anyerror {
            return null;
        }

        fn deadlineFn(_: *anyopaque) ?i128 {
            return null;
        }

        fn valueFn(_: *anyopaque, _: *const anyopaque) ?*const anyopaque {
            return null;
        }

        fn waitFn(_: *anyopaque, timeout_ns: ?i64) ?anyerror {
            if (timeout_ns) |ns| {
                if (ns <= 0) return null;
                lib.Thread.sleep(@intCast(ns));
                return null;
            }
            while (true) lib.Thread.sleep(embed.math.maxInt(u64));
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

    const Shared = struct {
        allocator: lib.mem.Allocator,
        background_impl: Background = .{},
        background_ctx: Context = undefined,
    };

    return struct {
        shared: *Shared,

        const Self = @This();
        pub const CancelContext = cancel_context.CancelContext(lib);
        pub const DeadlineContext = deadline_context.DeadlineContext(lib);
        pub fn ValueContext(comptime T: type) type {
            return value_context.ValueContext(lib, T);
        }

        pub fn init(allocator: lib.mem.Allocator) lib.mem.Allocator.Error!Self {
            const shared = try allocator.create(Shared);
            shared.* = .{
                .allocator = allocator,
            };
            shared.background_ctx = Context.init(&shared.background_impl, &Background.vtable, allocator);
            shared.background_impl.tree.ctx = shared.background_ctx;
            return .{ .shared = shared };
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.shared.allocator;
            self.shared.background_impl.tree_rw.lock();
            const has_children = self.shared.background_impl.tree.children.first != null;
            self.shared.background_impl.tree_rw.unlock();
            if (has_children) @panic("context root deinit with active child");
            allocator.destroy(self.shared);
            self.* = undefined;
        }

        /// Create a cancelable child context.
        pub fn withCancel(self: *const Self, parent: Context) lib.mem.Allocator.Error!Context {
            _ = self;
            return CancelContext.init(parent.allocator, parent);
        }

        /// Create a context that auto-cancels at the given absolute deadline
        /// (nanoTimestamp). If the parent has an earlier deadline, that one
        /// takes effect instead.
        pub fn withDeadline(self: *const Self, parent: Context, deadline_ns: i128) lib.mem.Allocator.Error!Context {
            _ = self;
            return DeadlineContext.init(parent.allocator, parent, deadline_ns);
        }

        /// Create a context that auto-cancels after timeout_ns nanoseconds.
        /// Convenience wrapper over withDeadline.
        pub fn withTimeout(self: *const Self, parent: Context, timeout_ns: i64) lib.mem.Allocator.Error!Context {
            _ = self;
            return DeadlineContext.init(parent.allocator, parent, lib.time.nanoTimestamp() + timeout_ns);
        }

        /// Attach a typed key-value pair to the context chain.
        pub fn withValue(self: *const Self, comptime T: type, parent: Context, key: *const Context.Key(T), val: T) lib.mem.Allocator.Error!Context {
            _ = self;
            return ValueContext(T).init(parent.allocator, parent, key, val);
        }

        /// Root context. Never canceled, holds no values, no deadline.
        pub fn background(self: *const Self) Context {
            return self.shared.background_ctx;
        }
    };
}
