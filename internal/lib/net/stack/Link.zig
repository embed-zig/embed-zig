//! Link — type-erased low-level link for user-space network stacks.
//!
//! VTable-based runtime dispatch. Any concrete link with
//! read/write/timeout/deinit methods can be wrapped into a Link.
//!
//! Usage:
//!   var link = Link.init(&impl);
//!   const mtu = link.mtu();
//!   const n = try link.read(&buf);
//!   _ = try link.write(pkt);
//!
//! The concrete implementation defines the unit carried by the link.
//! A PPP implementation may frame bytes internally and expose complete
//! packets here, a TAP implementation may exchange Ethernet frames, and
//! a TUN implementation may exchange IP packets.
//!
//! `read()` and `write()` operate on one complete link unit. Callers
//! should provide a buffer large enough for the implementation's MTU.
const Link = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const ReadError = error{
    EndOfStream,
    TimedOut,
    LinkDown,
    ShortBuffer,
    BrokenLink,
    Unexpected,
};

pub const WriteError = error{
    TimedOut,
    LinkDown,
    BrokenLink,
    MessageTooLong,
    Unexpected,
};

pub const VTable = struct {
    mtu: *const fn (ptr: *anyopaque) usize,
    read: *const fn (ptr: *anyopaque, buf: []u8) ReadError!usize,
    write: *const fn (ptr: *anyopaque, buf: []const u8) WriteError!usize,
    setReadDeadline: *const fn (ptr: *anyopaque, epoch_ms: i64) void,
    setWriteDeadline: *const fn (ptr: *anyopaque, epoch_ms: i64) void,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub fn mtu(self: Link) usize {
    return self.vtable.mtu(self.ptr);
}

pub fn read(self: Link, buf: []u8) ReadError!usize {
    return self.vtable.read(self.ptr, buf);
}

pub fn write(self: Link, buf: []const u8) WriteError!usize {
    return self.vtable.write(self.ptr, buf);
}

pub fn setReadDeadline(self: Link, epoch_ms: i64) void {
    self.vtable.setReadDeadline(self.ptr, epoch_ms);
}

pub fn setWriteDeadline(self: Link, epoch_ms: i64) void {
    self.vtable.setWriteDeadline(self.ptr, epoch_ms);
}

pub fn deinit(self: Link) void {
    self.vtable.deinit(self.ptr);
}

pub fn init(pointer: anytype) Link {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Link.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn mtuFn(ptr: *anyopaque) usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.mtu();
        }

        fn readFn(ptr: *anyopaque, buf: []u8) ReadError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.read(buf);
        }

        fn writeFn(ptr: *anyopaque, buf: []const u8) WriteError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.write(buf);
        }

        fn setReadDeadlineFn(ptr: *anyopaque, epoch_ms: i64) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setReadDeadline(epoch_ms);
        }

        fn setWriteDeadlineFn(ptr: *anyopaque, epoch_ms: i64) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setWriteDeadline(epoch_ms);
        }

        fn deinitFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        const vtable = VTable{
            .mtu = mtuFn,
            .read = readFn,
            .write = writeFn,
            .setReadDeadline = setReadDeadlineFn,
            .setWriteDeadline = setWriteDeadlineFn,
            .deinit = deinitFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}
