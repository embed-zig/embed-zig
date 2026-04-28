//! PacketConn — type-erased datagram interface (like Go's net.PacketConn).
//!
//! VTable-based runtime dispatch, same pattern as Conn and Listener.
//! Concrete implementations must also provide close/deinit and deadline setter
//! methods. For connectionless protocols (UDP), each readFrom/writeTo operates
//! on a single datagram with an associated remote address.
//!
//! Usage:
//!   var pc = try net.listenPacket(.{ .allocator = allocator });
//!   defer pc.deinit();
//!   var buf: [512]u8 = undefined;
//!   const result = try pc.readFrom(&buf);
//!   _ = try pc.writeTo("reply", result.addr);
//!
//! Concurrency note:
//! implementations may support one blocked reader and one blocked writer at the
//! same time, but concurrent operations in the same direction are not part of
//! the shared PacketConn contract.

const time_mod = @import("time");

const PacketConn = @This();
const AddrPort = @import("netip/AddrPort.zig");

ptr: *anyopaque,
vtable: *const VTable,
type_id: *const anyopaque,

pub const VTable = struct {
    readFrom: *const fn (ptr: *anyopaque, buf: []u8) ReadFromError!ReadFromResult,
    writeTo: *const fn (ptr: *anyopaque, buf: []const u8, addr: AddrPort) WriteToError!usize,
    close: *const fn (ptr: *anyopaque) void,
    deinit: *const fn (ptr: *anyopaque) void,
    setReadDeadline: *const fn (ptr: *anyopaque, deadline: ?time_mod.instant.Time) void,
    setWriteDeadline: *const fn (ptr: *anyopaque, deadline: ?time_mod.instant.Time) void,
};

pub const ReadFromResult = struct {
    bytes_read: usize,
    addr: AddrPort,
};

pub const ReadFromError = error{
    ConnectionReset,
    Closed,
    ConnectionRefused,
    TimedOut,
    Unexpected,
};

pub const WriteToError = error{
    Closed,
    MessageTooLong,
    NetworkUnreachable,
    AccessDenied,
    TimedOut,
    Unexpected,
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

/// Safe downcast: returns a pointer to the underlying impl if the type matches.
pub fn as(self: PacketConn, comptime T: type) error{TypeMismatch}!*T {
    if (self.type_id == typeId(T)) return @ptrCast(@alignCast(self.ptr));
    return error.TypeMismatch;
}

pub fn readFrom(self: PacketConn, buf: []u8) ReadFromError!ReadFromResult {
    return self.vtable.readFrom(self.ptr, buf);
}

pub fn writeTo(self: PacketConn, buf: []const u8, addr: AddrPort) WriteToError!usize {
    return self.vtable.writeTo(self.ptr, buf, addr);
}

pub fn close(self: PacketConn) void {
    self.vtable.close(self.ptr);
}

pub fn deinit(self: PacketConn) void {
    self.close();
    self.vtable.deinit(self.ptr);
}

pub fn setReadDeadline(self: PacketConn, deadline: ?time_mod.instant.Time) void {
    self.vtable.setReadDeadline(self.ptr, deadline);
}

pub fn setWriteDeadline(self: PacketConn, deadline: ?time_mod.instant.Time) void {
    self.vtable.setWriteDeadline(self.ptr, deadline);
}

/// Wrap a pointer to any concrete type that matches the `PacketConn` vtable contract.
///
/// The concrete type must provide:
///   fn readFrom(*Self, []u8) ReadFromError!ReadFromResult
///   fn writeTo(*Self, []const u8, AddrPort) WriteToError!usize
///   fn close(*Self) void
///   fn deinit(*Self) void
///   fn setReadDeadline(*Self, ?time_mod.instant.Time) void
///   fn setWriteDeadline(*Self, ?time_mod.instant.Time) void
pub fn init(pointer: anytype) PacketConn {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("PacketConn.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn readFromFn(ptr: *anyopaque, buf: []u8) ReadFromError!ReadFromResult {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.readFrom(buf);
        }
        fn writeToFn(ptr: *anyopaque, buf: []const u8, addr: AddrPort) WriteToError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.writeTo(buf, addr);
        }
        fn closeFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.close();
        }

        const vtable = VTable{
            .readFrom = readFromFn,
            .writeTo = writeToFn,
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
