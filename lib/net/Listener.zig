//! Listener — type-erased stream listener (like Go's net.Listener).
//!
//! VTable-based runtime dispatch. Any concrete listener type with
//! accept/close/addr methods can be wrapped into a Listener.
//!
//! Usage:
//!   var tcp_ln = try TcpListener.init(lib, .{ .port = 8080 });
//!   var ln = tcp_ln.listener();   // type-erase into Listener
//!   defer ln.close();
//!   while (true) {
//!       var conn = try ln.accept();
//!       // handle conn...
//!   }

const Conn = @import("Conn.zig");

const Listener = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    accept: *const fn (ptr: *anyopaque) AcceptError!Conn,
    close: *const fn (ptr: *anyopaque) void,
};

pub const AcceptError = error{
    ConnectionAborted,
    SocketNotListening,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    Unexpected,
};

pub fn accept(self: Listener) AcceptError!Conn {
    return self.vtable.accept(self.ptr);
}

pub fn close(self: Listener) void {
    self.vtable.close(self.ptr);
}

/// Wrap a pointer to any concrete listener type into a Listener.
///
/// The concrete type must provide:
///   fn accept(*Self) AcceptError!Conn
///   fn close(*Self) void
pub fn init(pointer: anytype) Listener {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Listener.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn acceptFn(ptr: *anyopaque) AcceptError!Conn {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.accept();
        }
        fn closeFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.close();
        }

        const vtable = VTable{
            .accept = acceptFn,
            .close = closeFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}
