//! Conn — type-erased bidirectional byte stream (like Go's net.Conn).
//!
//! Uses a VTable for runtime dispatch, same pattern as std.mem.Allocator.
//! Any concrete type with read/write/close methods can be wrapped into a Conn.
//!
//! Usage:
//!   const Addr = lib.net.Address;
//!   var conn = try net.dial(allocator, Addr.initIp4(.{127,0,0,1}, 80));
//!   defer conn.deinit();
//!   _ = try conn.write("hello");
//!   const n = try conn.read(&buf);

const Conn = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    read: *const fn (ptr: *anyopaque, buf: []u8) ReadError!usize,
    write: *const fn (ptr: *anyopaque, buf: []const u8) WriteError!usize,
    close: *const fn (ptr: *anyopaque) void,
    deinit: *const fn (ptr: *anyopaque) void,
    setReadTimeout: *const fn (ptr: *anyopaque, ms: ?u32) void,
    setWriteTimeout: *const fn (ptr: *anyopaque, ms: ?u32) void,
};

pub const ReadError = error{
    EndOfStream,
    ConnectionReset,
    ConnectionRefused,
    BrokenPipe,
    TimedOut,
    Unexpected,
};

pub const WriteError = error{
    ConnectionReset,
    BrokenPipe,
    TimedOut,
    Unexpected,
};

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

pub fn setReadTimeout(self: Conn, ms: ?u32) void {
    self.vtable.setReadTimeout(self.ptr, ms);
}

pub fn setWriteTimeout(self: Conn, ms: ?u32) void {
    self.vtable.setWriteTimeout(self.ptr, ms);
}

/// Read exactly buf.len bytes or return error.
pub fn readAll(self: Conn, buf: []u8) ReadError!void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = try self.read(buf[filled..]);
        if (n == 0) return error.EndOfStream;
        filled += n;
    }
}

/// Write all bytes or return error.
pub fn writeAll(self: Conn, buf: []const u8) WriteError!void {
    var written: usize = 0;
    while (written < buf.len) {
        written += try self.write(buf[written..]);
    }
}

/// Wrap a pointer to any concrete type that has read/write/close into a Conn.
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
            .setReadTimeout = setReadTimeoutFn,
            .setWriteTimeout = setWriteTimeoutFn,
        };

        fn deinitFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
        fn setReadTimeoutFn(ptr: *anyopaque, ms: ?u32) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setReadTimeout(ms);
        }
        fn setWriteTimeoutFn(ptr: *anyopaque, ms: ?u32) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setWriteTimeout(ms);
        }
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}
