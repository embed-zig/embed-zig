//! File — type-erased runtime file handle.

const File = @This();

ptr: *anyopaque,
vtable: *const VTable,
type_id: *const anyopaque,

pub const SeekWhence = enum {
    start,
    current,
    end,
};

pub const VTable = struct {
    read: *const fn (ptr: *anyopaque, buf: []u8) ReadError!usize,
    write: *const fn (ptr: *anyopaque, buf: []const u8) WriteError!usize,
    seek: *const fn (ptr: *anyopaque, offset: i64, whence: SeekWhence) SeekError!u64,
    sync: *const fn (ptr: *anyopaque) SyncError!void,
    close: *const fn (ptr: *anyopaque) void,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub const ReadError = error{
    EndOfStream,
    Unexpected,
};

pub const WriteError = error{
    AccessDenied,
    NoSpaceLeft,
    Unexpected,
};

pub const SeekError = error{
    Unsupported,
    Unexpected,
};

pub const SyncError = error{
    Unsupported,
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

pub fn as(self: File, comptime T: type) error{TypeMismatch}!*T {
    if (self.type_id == typeId(T)) return @ptrCast(@alignCast(self.ptr));
    return error.TypeMismatch;
}

pub fn read(self: File, buf: []u8) ReadError!usize {
    return self.vtable.read(self.ptr, buf);
}

pub fn write(self: File, buf: []const u8) WriteError!usize {
    return self.vtable.write(self.ptr, buf);
}

pub fn seek(self: File, offset: i64, whence: SeekWhence) SeekError!u64 {
    return self.vtable.seek(self.ptr, offset, whence);
}

pub fn sync(self: File) SyncError!void {
    return self.vtable.sync(self.ptr);
}

pub fn close(self: File) void {
    self.vtable.close(self.ptr);
}

pub fn deinit(self: File) void {
    self.close();
    self.vtable.deinit(self.ptr);
}

pub fn init(pointer: anytype) File {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("File.init expects a single-item pointer");

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

        fn seekFn(ptr: *anyopaque, offset: i64, whence: SeekWhence) SeekError!u64 {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.seek(offset, whence);
        }

        fn syncFn(ptr: *anyopaque) SyncError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.sync();
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
            .read = readFn,
            .write = writeFn,
            .seek = seekFn,
            .sync = syncFn,
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
