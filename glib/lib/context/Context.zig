//! Context — type-erased owning interface for cancellation and values.
//!
//! Context values are small owning handles. The creator of a derived context is
//! responsible for calling `deinit()`. Passing a Context to other APIs borrows
//! the underlying node; those APIs must not deinit it.

const stdz = @import("stdz");
const time_mod = @import("time");
const binding_link = @import("BindingLink.zig");

const Context = @This();

pub const DoublyLinkedList = stdz.DoublyLinkedList;
pub const BindingLink = binding_link;

ptr: *anyopaque,
vtable: *const VTable,
type_id: *const anyopaque = typeId(UnknownContext),
allocator: stdz.mem.Allocator,

pub const TreeLink = struct {
    ctx: Context = undefined,
    parent: ?Context = null,
    children: DoublyLinkedList = .{},
    binding: ?BindingLink = null,
    node: DoublyLinkedList.Node = .{},

    pub fn fromNode(n: *DoublyLinkedList.Node) *TreeLink {
        return @fieldParentPtr("node", n);
    }
};

pub const VTable = struct {
    errFn: *const fn (ptr: *anyopaque) ?anyerror,
    errNoLockFn: *const fn (ptr: *anyopaque) ?anyerror,
    deadlineFn: *const fn (ptr: *anyopaque) ?time_mod.instant.Time,
    deadlineNoLockFn: *const fn (ptr: *anyopaque) ?time_mod.instant.Time,
    valueFn: *const fn (ptr: *anyopaque, key: *const anyopaque) ?*const anyopaque,
    valueNoLockFn: *const fn (ptr: *anyopaque, key: *const anyopaque) ?*const anyopaque,
    waitFn: *const fn (ptr: *anyopaque, timeout: ?time_mod.duration.Duration) ?anyerror,
    cancelFn: *const fn (ptr: *anyopaque) void,
    cancelWithCauseFn: *const fn (ptr: *anyopaque, cause: anyerror) void,
    propagateCancelWithCauseFn: *const fn (ptr: *anyopaque, cause: anyerror) void,
    deinitFn: *const fn (ptr: *anyopaque) void,
    treeFn: *const fn (ptr: *anyopaque) *TreeLink,
    treeLockFn: *const fn (ptr: *anyopaque) *anyopaque,
    reparentFn: *const fn (ptr: *anyopaque, parent: ?Context) void,
    lockSharedFn: *const fn (ptr: *anyopaque) void,
    unlockSharedFn: *const fn (ptr: *anyopaque) void,
    lockFn: *const fn (ptr: *anyopaque) void,
    unlockFn: *const fn (ptr: *anyopaque) void,
};

pub const Canceled = error.Canceled;
pub const DeadlineExceeded = error.DeadlineExceeded;
pub const StateError = error{
    Canceled,
    DeadlineExceeded,
};

fn TypeIdHolder(comptime T: type) type {
    return struct {
        comptime _phantom: type = T,
        var id: u8 = 0;
    };
}

fn typeId(comptime T: type) *const anyopaque {
    return @ptrCast(&TypeIdHolder(T).id);
}

const UnknownContext = struct {};

/// Non-blocking check: returns the cancellation cause, or null if still active.
pub fn err(self: Context) ?anyerror {
    return self.vtable.errFn(self.ptr);
}

/// Returns the monotonic instant deadline if one is set, or null.
pub fn deadline(self: Context) ?time_mod.instant.Time {
    return self.vtable.deadlineFn(self.ptr);
}

/// Block until canceled or timeout. Returns the cause error, or null if the
/// timeout expired before cancellation.
pub fn wait(self: Context, timeout: ?time_mod.duration.Duration) ?anyerror {
    return self.vtable.waitFn(self.ptr, timeout);
}

pub fn checkState(self: Context) StateError!void {
    const cause = self.err() orelse return;
    if (cause == error.DeadlineExceeded) return error.DeadlineExceeded;
    return error.Canceled;
}

pub fn cancel(self: Context) void {
    self.vtable.cancelFn(self.ptr);
}

pub fn cancelWithCause(self: Context, cause: anyerror) void {
    self.vtable.cancelWithCauseFn(self.ptr, cause);
}

pub fn deinit(self: Context) void {
    self.bindLink(null) catch unreachable;
    self.vtable.deinitFn(self.ptr);
}

/// Look up a typed value by key. Walks the parent chain until found or root.
pub fn value(self: Context, comptime T: type, key: *const Key(T)) ?T {
    const raw = self.vtable.valueFn(self.ptr, @ptrCast(key)) orelse return null;
    return @as(*const T, @ptrCast(@alignCast(raw))).*;
}

pub fn bindLink(self: Context, binding: ?BindingLink) error{AlreadyBound}!void {
    var old_binding: ?BindingLink = null;
    var canceled_cause: ?anyerror = null;

    self.vtable.lockFn(self.ptr);
    const tree_link = self.vtable.treeFn(self.ptr);
    if (binding == null) {
        old_binding = tree_link.binding;
        tree_link.binding = null;
    } else if (tree_link.binding != null) {
        self.vtable.unlockFn(self.ptr);
        return error.AlreadyBound;
    } else if (self.vtable.errNoLockFn(self.ptr)) |cause| {
        canceled_cause = cause;
    } else {
        tree_link.binding = binding;
    }
    self.vtable.unlockFn(self.ptr);

    if (old_binding) |old| old.deactivate();
    if (canceled_cause) |cause| binding.?.fire(cause);
}

pub fn bindFd(self: Context, comptime std: type, fd: *std.posix.socket_t) error{AlreadyBound}!void {
    return self.bindLink(BindingLink.fdLink(std, fd));
}

pub fn as(self: Context, comptime T: type) error{TypeMismatch}!*T {
    if (self.type_id == typeId(T)) return @ptrCast(@alignCast(self.ptr));
    return error.TypeMismatch;
}

pub fn init(pointer: anytype, vtable: *const VTable, allocator: stdz.mem.Allocator) Context {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Context.init expects a single-item pointer");

    const Impl = info.pointer.child;
    return .{
        .ptr = pointer,
        .vtable = vtable,
        .type_id = typeId(Impl),
        .allocator = allocator,
    };
}

/// Type-safe context key. Each key must be a unique `var`.
pub fn Key(comptime T: type) type {
    _ = T;
    return struct {
        _: u8 = 0,
    };
}
