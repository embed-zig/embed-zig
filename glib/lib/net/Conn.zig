//! Conn — type-erased bidirectional byte stream (like Go's net.Conn).
//!
//! Uses a VTable for runtime dispatch, same pattern as std.mem.Allocator.
//! Any concrete type with read/write/close/deinit plus deadline setter methods
//! can be wrapped into a Conn.
//!
//!   var conn = try net.dial(allocator, .tcp, addr);
//!   defer conn.deinit();
//!
//!   // raw I/O
//!   _ = try conn.write("hello");
//!   const n = try conn.read(&buf);
//!
//! Concurrency note:
//! implementations may support one blocked reader and one blocked writer at the
//! same time, but concurrent operations in the same direction are not part of
//! the shared Conn contract.

const time_mod = @import("time");

const Conn = @This();

ptr: *anyopaque,
vtable: *const VTable,
type_id: *const anyopaque,

pub const VTable = struct {
    read: *const fn (ptr: *anyopaque, buf: []u8) ReadError!usize,
    write: *const fn (ptr: *anyopaque, buf: []const u8) WriteError!usize,
    close: *const fn (ptr: *anyopaque) void,
    deinit: *const fn (ptr: *anyopaque) void,
    setReadDeadline: *const fn (ptr: *anyopaque, deadline: ?time_mod.instant.Time) void,
    setWriteDeadline: *const fn (ptr: *anyopaque, deadline: ?time_mod.instant.Time) void,
};

pub const ReadError = error{
    EndOfStream,
    ShortRead,
    ConnectionReset,
    ConnectionRefused,
    BrokenPipe,
    TimedOut,
    Unexpected,
};

pub const WriteError = error{
    ConnectionRefused,
    ConnectionReset,
    BrokenPipe,
    TimedOut,
    Unexpected,
};

/// Comptime type ID: each distinct type T gets a unique address.
fn TypeIdHolder(comptime T: type) type {
    return struct {
        comptime _phantom: type = T,
        var id: u8 = 0;
    };
}

fn typeId(comptime T: type) *const anyopaque {
    return @ptrCast(&TypeIdHolder(T).id);
}

/// Safe downcast: returns a pointer to the underlying impl if the type matches.
pub fn as(self: Conn, comptime T: type) error{TypeMismatch}!*T {
    if (self.type_id == typeId(T)) return @ptrCast(@alignCast(self.ptr));
    return error.TypeMismatch;
}

pub fn read(self: Conn, buf: []u8) ReadError!usize {
    return self.vtable.read(self.ptr, buf);
}

pub fn write(self: Conn, buf: []const u8) WriteError!usize {
    return self.vtable.write(self.ptr, buf);
}

pub fn close(self: Conn) void {
    self.vtable.close(self.ptr);
}

/// Close the connection and free the underlying heap allocation.
pub fn deinit(self: Conn) void {
    self.close();
    self.vtable.deinit(self.ptr);
}

pub fn setReadDeadline(self: Conn, deadline: ?time_mod.instant.Time) void {
    self.vtable.setReadDeadline(self.ptr, deadline);
}

pub fn setWriteDeadline(self: Conn, deadline: ?time_mod.instant.Time) void {
    self.vtable.setWriteDeadline(self.ptr, deadline);
}

/// Wrap a pointer to any concrete type that matches the `Conn` vtable contract.
///
/// The concrete type must provide:
///   fn read(*Self, []u8) ReadError!usize
///   fn write(*Self, []const u8) WriteError!usize
///   fn close(*Self) void
///   fn deinit(*Self) void
///   fn setReadDeadline(*Self, ?time_mod.instant.Time) void
///   fn setWriteDeadline(*Self, ?time_mod.instant.Time) void
pub fn init(pointer: anytype) Conn {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Conn.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn readFn(ptr: *anyopaque, buf: []u8) ReadError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.read(buf);
        }
        fn writeFn(ptr: *anyopaque, buf: []const u8) WriteError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.write(buf);
        }
        fn closeFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.close();
        }

        const vtable = VTable{
            .read = readFn,
            .write = writeFn,
            .close = closeFn,
            .deinit = deinitFn,
            .setReadDeadline = setReadDeadlineFn,
            .setWriteDeadline = setWriteDeadlineFn,
        };

        fn deinitFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
        fn setReadDeadlineFn(ptr: *anyopaque, deadline: ?time_mod.instant.Time) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setReadDeadline(deadline);
        }
        fn setWriteDeadlineFn(ptr: *anyopaque, deadline: ?time_mod.instant.Time) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setWriteDeadline(deadline);
        }
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
        .type_id = typeId(Impl),
    };
}
