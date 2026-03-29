//! Context — type-erased owning interface for cancellation and values.
//!
//! Context values are small owning handles. The creator of a derived context is
//! responsible for calling `deinit()`. Passing a Context to other APIs borrows
//! the underlying node; those APIs must not deinit it.

const embed = @import("embed");

const Context = @This();

pub const DoublyLinkedList = embed.collections.DoublyLinkedList;

ptr: *anyopaque,
vtable: *const VTable,
type_id: *const anyopaque = typeId(UnknownContext),
allocator: embed.mem.Allocator,

pub const TreeLink = struct {
    ctx: Context = undefined,
    parent: ?Context = null,
    children: DoublyLinkedList = .{},
    node: DoublyLinkedList.Node = .{},

    pub fn fromNode(n: *DoublyLinkedList.Node) *TreeLink {
        return @fieldParentPtr("node", n);
    }
};

pub const VTable = struct {
    errFn: *const fn (ptr: *anyopaque) ?anyerror,
    deadlineFn: *const fn (ptr: *anyopaque) ?i128,
    valueFn: *const fn (ptr: *anyopaque, key: *const anyopaque) ?*const anyopaque,
    waitFn: *const fn (ptr: *anyopaque, timeout_ns: ?i64) ?anyerror,
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

/// Returns the deadline (nanoTimestamp) if one is set, or null.
pub fn deadline(self: Context) ?i128 {
    return self.vtable.deadlineFn(self.ptr);
}

/// Block until canceled or timeout. Returns the cause error, or null if the
/// timeout expired before cancellation.
pub fn wait(self: Context, timeout_ns: ?i64) ?anyerror {
    return self.vtable.waitFn(self.ptr, timeout_ns);
}

pub fn cancel(self: Context) void {
    self.vtable.cancelFn(self.ptr);
}

pub fn cancelWithCause(self: Context, cause: anyerror) void {
    self.vtable.cancelWithCauseFn(self.ptr, cause);
}

pub fn deinit(self: Context) void {
    self.vtable.deinitFn(self.ptr);
}

/// Look up a typed value by key. Walks the parent chain until found or root.
pub fn value(self: Context, comptime T: type, key: *const Key(T)) ?T {
    const raw = self.vtable.valueFn(self.ptr, @ptrCast(key)) orelse return null;
    return @as(*const T, @ptrCast(@alignCast(raw))).*;
}

pub fn as(self: Context, comptime T: type) error{TypeMismatch}!*T {
    if (self.type_id == typeId(T)) return @ptrCast(@alignCast(self.ptr));
    return error.TypeMismatch;
}

pub fn init(pointer: anytype, vtable: *const VTable, allocator: embed.mem.Allocator) Context {
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
