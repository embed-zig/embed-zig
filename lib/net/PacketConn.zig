//! PacketConn — type-erased datagram interface (like Go's net.PacketConn).
//!
//! VTable-based runtime dispatch, same pattern as Conn and Listener.
//! For connectionless protocols (UDP). Each readFrom/writeTo operates
//! on a single datagram with an associated remote address.
//!
//! Usage:
//!   var uc = try net.listenPacket(allocator, .{});
//!   defer uc.close();
//!   var buf: [512]u8 = undefined;
//!   const result = try uc.readFrom(&buf);
//!   _ = try uc.writeTo("reply", &result.addr, result.addr_len);

const PacketConn = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    readFrom: *const fn (ptr: *anyopaque, buf: []u8) ReadFromError!ReadFromResult,
    writeTo: *const fn (ptr: *anyopaque, buf: []const u8, addr: [*]const u8, addr_len: u32) WriteToError!usize,
    close: *const fn (ptr: *anyopaque) void,
    deinit: ?*const fn (ptr: *anyopaque) void = null,
};

pub const AddrStorage = [128]u8;

pub const ReadFromResult = struct {
    bytes_read: usize,
    addr: AddrStorage,
    addr_len: u32,
};

pub const ReadFromError = error{
    WouldBlock,
    ConnectionRefused,
    TimedOut,
    Unexpected,
};

pub const WriteToError = error{
    MessageTooLong,
    NetworkUnreachable,
    AccessDenied,
    TimedOut,
    Unexpected,
};

pub fn readFrom(self: PacketConn, buf: []u8) ReadFromError!ReadFromResult {
    return self.vtable.readFrom(self.ptr, buf);
}

pub fn writeTo(self: PacketConn, buf: []const u8, addr: [*]const u8, addr_len: u32) WriteToError!usize {
    return self.vtable.writeTo(self.ptr, buf, addr, addr_len);
}

pub fn close(self: PacketConn) void {
    self.vtable.close(self.ptr);
}

pub fn deinit(self: PacketConn) void {
    self.close();
    if (self.vtable.deinit) |f| f(self.ptr);
}

/// Wrap a pointer to any concrete type that has readFrom/writeTo/close
/// into a PacketConn.
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
        fn writeToFn(ptr: *anyopaque, buf: []const u8, addr: [*]const u8, addr_len: u32) WriteToError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.writeTo(buf, addr, addr_len);
        }
        fn closeFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.close();
        }

        const vtable = VTable{
            .readFrom = readFromFn,
            .writeTo = writeToFn,
            .close = closeFn,
            .deinit = if (@hasDecl(Impl, "deinit")) deinitFn else null,
        };

        fn deinitFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}
