//! Transport — type-erased HCI transport (like net.Conn for byte streams).
//!
//! VTable-based runtime dispatch. Any concrete transport with
//! read/write/reset methods can be wrapped into a Transport.
//!
//! Only used by the built-in HCI host stack. OS-level backends
//! (CoreBluetooth, Android BLE) do not need a Transport.
//!
//! Usage:
//!   var h4 = H4Uart.init(&uart);
//!   var transport = Transport.init(&h4);
//!   const HciType = @import("bt/host/Hci.zig").Hci(embed);
//!   var hci = HciType.init(transport, .{});

const root = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    write: *const fn (ptr: *anyopaque, buf: []const u8) WriteError!usize,
    read: *const fn (ptr: *anyopaque, buf: []u8) ReadError!usize,
    reset: *const fn (ptr: *anyopaque) void,
    deinit: *const fn (ptr: *anyopaque) void,
    setReadDeadline: *const fn (ptr: *anyopaque, deadline_ns: ?i64) void,
    setWriteDeadline: *const fn (ptr: *anyopaque, deadline_ns: ?i64) void,
};

pub const WriteError = error{
    Timeout,
    HwError,
    Unexpected,
};

pub const ReadError = error{
    Timeout,
    HwError,
    Unexpected,
};

pub const SendError = WriteError;
pub const RecvError = ReadError;

pub fn write(self: root, buf: []const u8) WriteError!usize {
    return self.vtable.write(self.ptr, buf);
}

pub fn read(self: root, buf: []u8) ReadError!usize {
    return self.vtable.read(self.ptr, buf);
}

pub fn reset(self: root) void {
    self.vtable.reset(self.ptr);
}

pub fn setReadDeadline(self: root, deadline_ns: ?i64) void {
    self.vtable.setReadDeadline(self.ptr, deadline_ns);
}

pub fn setWriteDeadline(self: root, deadline_ns: ?i64) void {
    self.vtable.setWriteDeadline(self.ptr, deadline_ns);
}

pub fn deinit(self: root) void {
    self.vtable.deinit(self.ptr);
}

pub fn init(pointer: anytype) root {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Transport.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn writeFn(ptr: *anyopaque, buf: []const u8) WriteError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.write(buf);
        }
        fn readFn(ptr: *anyopaque, buf: []u8) ReadError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.read(buf);
        }
        fn resetFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.reset();
        }
        fn deinitFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
        fn setReadDeadlineFn(ptr: *anyopaque, deadline_ns: ?i64) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setReadDeadline(deadline_ns);
        }
        fn setWriteDeadlineFn(ptr: *anyopaque, deadline_ns: ?i64) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setWriteDeadline(deadline_ns);
        }

        const vtable = VTable{
            .write = writeFn,
            .read = readFn,
            .reset = resetFn,
            .deinit = deinitFn,
            .setReadDeadline = setReadDeadlineFn,
            .setWriteDeadline = setWriteDeadlineFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}
