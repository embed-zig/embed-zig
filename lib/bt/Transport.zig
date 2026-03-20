//! Transport — type-erased HCI transport (like net.Conn for byte streams).
//!
//! VTable-based runtime dispatch. Any concrete transport with
//! send/recv/reset methods can be wrapped into a Transport.
//!
//! Only used by the built-in HCI host stack. OS-level backends
//! (CoreBluetooth, Android BLE) do not need a Transport.
//!
//! Usage:
//!   var h4 = H4Uart.init(&uart);
//!   var transport = Transport.init(&h4);
//!   var hci = Hci.init(transport, allocator);

const Transport = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    send: *const fn (ptr: *anyopaque, buf: []const u8) SendError!void,
    recv: *const fn (ptr: *anyopaque, buf: []u8) RecvError!usize,
    reset: *const fn (ptr: *anyopaque) void,
    deinit: *const fn (ptr: *anyopaque) void,
    setRecvTimeout: *const fn (ptr: *anyopaque, ms: ?u32) void,
    setSendTimeout: *const fn (ptr: *anyopaque, ms: ?u32) void,
};

pub const SendError = error{
    Timeout,
    HwError,
    Unexpected,
};

pub const RecvError = error{
    Timeout,
    HwError,
    Unexpected,
};

pub fn send(self: Transport, buf: []const u8) SendError!void {
    return self.vtable.send(self.ptr, buf);
}

pub fn recv(self: Transport, buf: []u8) RecvError!usize {
    return self.vtable.recv(self.ptr, buf);
}

pub fn reset(self: Transport) void {
    self.vtable.reset(self.ptr);
}

pub fn setRecvTimeout(self: Transport, ms: ?u32) void {
    self.vtable.setRecvTimeout(self.ptr, ms);
}

pub fn setSendTimeout(self: Transport, ms: ?u32) void {
    self.vtable.setSendTimeout(self.ptr, ms);
}

pub fn deinit(self: Transport) void {
    self.vtable.deinit(self.ptr);
}

pub fn init(pointer: anytype) Transport {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Transport.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn sendFn(ptr: *anyopaque, buf: []const u8) SendError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.send(buf);
        }
        fn recvFn(ptr: *anyopaque, buf: []u8) RecvError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.recv(buf);
        }
        fn resetFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.reset();
        }
        fn deinitFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
        fn setRecvTimeoutFn(ptr: *anyopaque, ms: ?u32) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setRecvTimeout(ms);
        }
        fn setSendTimeoutFn(ptr: *anyopaque, ms: ?u32) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setSendTimeout(ms);
        }

        const vtable = VTable{
            .send = sendFn,
            .recv = recvFn,
            .reset = resetFn,
            .deinit = deinitFn,
            .setRecvTimeout = setRecvTimeoutFn,
            .setSendTimeout = setSendTimeoutFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}
