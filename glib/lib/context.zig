//! context — Go-style context for cancellation propagation and value passing.
//!
//! Supports cancel-with-cause (like Go's WithCancelCause), deadline, and
//! timeout. The default cancel() uses error.Canceled; withDeadline uses
//! error.DeadlineExceeded.
//!
//! Usage:
//!   const Context = @import("context").make(std, time);
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
//!   // Deadline (monotonic instant):
//!   var dc = try context.withDeadline(
//!       bg,
//!       @import("time").instant.add(context.now(), 5 * @import("time").duration.MilliSecond),
//!   );
//!   defer dc.deinit();
//!
//!   // Timeout (relative duration):
//!   var tc = try context.withTimeout(bg, 5 * @import("time").duration.MilliSecond);
//!   defer tc.deinit();
//!
//!   // Bind a wake fd to an existing context:
//!   var wake_fd = some_posix_socket;
//!   try cancel_ctx.bindFd(std, &wake_fd);

const stdz = @import("stdz");
const time_mod = @import("time");
pub const Context = @import("context/Context.zig");
const cancel_context = @import("context/CancelContext.zig");
const deadline_context = @import("context/DeadlineContext.zig");
const internal = @import("context/internal.zig");
const value_context = @import("context/ValueContext.zig");

pub fn make(comptime std: type, comptime time: type) type {
    const Background = struct {
        tree: Context.TreeLink = .{},
        tree_rw: std.Thread.RwLock = .{},

        const Self = @This();

        fn errFn(_: *anyopaque) ?anyerror {
            return null;
        }

        fn errNoLockFn(_: *anyopaque) ?anyerror {
            return null;
        }

        fn deadlineFn(_: *anyopaque) ?time_mod.instant.Time {
            return null;
        }

        fn deadlineNoLockFn(_: *anyopaque) ?time_mod.instant.Time {
            return null;
        }

        fn valueFn(_: *anyopaque, _: *const anyopaque) ?*const anyopaque {
            return null;
        }

        fn valueNoLockFn(_: *anyopaque, _: *const anyopaque) ?*const anyopaque {
            return null;
        }

        fn waitFn(_: *anyopaque, timeout: ?time_mod.duration.Duration) ?anyerror {
            if (timeout) |duration| {
                if (duration <= 0) return null;
                std.Thread.sleep(@intCast(duration));
                return null;
            }
            while (true) std.Thread.sleep(stdz.math.maxInt(u64));
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

    const Shared = struct {
        allocator: std.mem.Allocator,
        background_impl: Background = .{},
        background_ctx: Context = undefined,
    };

    return struct {
        shared: *Shared,

        const Self = @This();
        pub const CancelContext = cancel_context.make(std, time);
        pub const DeadlineContext = deadline_context.make(std, time);
        pub fn ValueContext(comptime T: type) type {
            return value_context.make(std, time, T);
        }

        pub fn now(self: *const Self) time_mod.instant.Time {
            _ = self;
            return time.instant.now();
        }

        pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
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
            self.shared.background_ctx.deinit();
            allocator.destroy(self.shared);
            self.* = undefined;
        }

        /// Create a cancelable child context.
        pub fn withCancel(self: *const Self, parent: Context) std.mem.Allocator.Error!Context {
            _ = self;
            return CancelContext.init(parent.allocator, parent);
        }

        /// Create a context that auto-cancels at the given monotonic instant
        /// deadline. If the parent has an earlier deadline, that one
        /// takes effect instead.
        pub fn withDeadline(self: *const Self, parent: Context, deadline: time_mod.instant.Time) std.mem.Allocator.Error!Context {
            _ = self;
            return DeadlineContext.init(parent.allocator, parent, deadline);
        }

        /// Create a context that auto-cancels after a relative duration.
        /// Convenience wrapper over withDeadline.
        pub fn withTimeout(self: *const Self, parent: Context, timeout: time_mod.duration.Duration) std.mem.Allocator.Error!Context {
            _ = self;
            return DeadlineContext.init(parent.allocator, parent, internal.timeoutDeadline(time, timeout));
        }

        /// Attach a typed key-value pair to the context chain.
        pub fn withValue(self: *const Self, comptime T: type, parent: Context, key: *const Context.Key(T), val: T) std.mem.Allocator.Error!Context {
            _ = self;
            return ValueContext(T).init(parent.allocator, parent, key, val);
        }

        /// Root context. Never canceled, holds no values, no deadline.
        pub fn background(self: *const Self) Context {
            return self.shared.background_ctx;
        }
    };
}
