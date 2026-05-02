//! Listener — type-erased stream listener (like Go's net.Listener).
//!
//! VTable-based runtime dispatch. Any concrete listener type with
//! accept/close/deinit methods can be wrapped into a Listener.
//!
//! Usage:
//!   var ln = try TcpListener.init(allocator, .{
//!       .address = netip.AddrPort.from4(.{ 0, 0, 0, 0 }, 8080),
//!   });
//!   defer ln.deinit();
//!   try ln.listen();
//!
//!   const tcp_ln = try ln.as(TcpListener(lib));
//!   while (true) {
//!       var conn = try ln.accept();
//!       // handle conn...
//!   }
//!
//! Concurrency note:
//! concurrent `accept()` calls on the same Listener are not part of the shared
//! Listener contract. Use one accept loop and dispatch accepted connections to
//! workers when concurrent handling is needed.

const Conn = @import("Conn.zig");

const Listener = @This();

ptr: *anyopaque,
vtable: *const VTable,
type_id: *const anyopaque,

pub const VTable = struct {
    listen: *const fn (ptr: *anyopaque) ListenError!void,
    accept: *const fn (ptr: *anyopaque) AcceptError!Conn,
    close: *const fn (ptr: *anyopaque) void,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub const ListenError = anyerror;

pub const AcceptError = error{
    Closed,
    ConnectionAborted,
    ConnectionResetByPeer,
    OutOfMemory,
    PermissionDenied,
    SocketNotListening,
    Unexpected,
};

pub fn accept(self: Listener) AcceptError!Conn {
    return self.vtable.accept(self.ptr);
}

pub fn listen(self: Listener) ListenError!void {
    return self.vtable.listen(self.ptr);
}

pub fn close(self: Listener) void {
    self.vtable.close(self.ptr);
}

pub fn deinit(self: Listener) void {
    self.close();
    self.vtable.deinit(self.ptr);
}

fn TypeIdHolder(comptime T: type) type {
    return struct {
        comptime _phantom: type = T,
        var id: u8 = 0;
    };
}

fn typeId(comptime T: type) *const anyopaque {
    return @ptrCast(&TypeIdHolder(T).id);
}

pub fn as(self: Listener, comptime T: type) error{TypeMismatch}!*T {
    if (self.type_id == typeId(T)) return @ptrCast(@alignCast(self.ptr));
    return error.TypeMismatch;
}

/// Wrap a pointer to any concrete listener type into a Listener.
///
/// The concrete type must provide:
///   fn listen(*Self) ListenError!void
///   fn accept(*Self) AcceptError!Conn
///   fn close(*Self) void
///   fn deinit(*Self) void
pub fn init(pointer: anytype) Listener {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Listener.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn listenFn(ptr: *anyopaque) ListenError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.listen();
        }
        fn acceptFn(ptr: *anyopaque) AcceptError!Conn {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.accept();
        }
        fn closeFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.close();
        }
        fn deinitFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        const vtable = VTable{
            .listen = listenFn,
            .accept = acceptFn,
            .close = closeFn,
            .deinit = deinitFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
        .type_id = typeId(Impl),
    };
}
