//! ReadCloser — type-erased readable stream with close semantics.
//!
//! Mirrors Go's `io.ReadCloser`: a small composable runtime contract that
//! combines `read` and `close` for HTTP request/response bodies.

const ReadCloser = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const ReadError = anyerror;

pub const VTable = struct {
    read: *const fn (ptr: *anyopaque, buf: []u8) ReadError!usize,
    close: *const fn (ptr: *anyopaque) void,
};

pub fn read(self: ReadCloser, buf: []u8) ReadError!usize {
    return self.vtable.read(self.ptr, buf);
}

pub fn close(self: ReadCloser) void {
    self.vtable.close(self.ptr);
}

pub fn init(pointer: anytype) ReadCloser {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("ReadCloser.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn readFn(ptr: *anyopaque, buf: []u8) ReadError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.read(buf);
        }

        fn closeFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.close();
        }

        const vtable = VTable{
            .read = readFn,
            .close = closeFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

test "net/unit_tests/http/ReadCloser/init_dispatches_read_and_close" {
    const std = @import("std");

    const MockBody = struct {
        payload: []const u8 = "hello",
        offset: usize = 0,
        closed: bool = false,

        pub fn read(self: *@This(), buf: []u8) ReadError!usize {
            const remaining = self.payload[self.offset..];
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            self.offset += n;
            return n;
        }

        pub fn close(self: *@This()) void {
            self.closed = true;
        }
    };

    var mock = MockBody{};
    const rc = ReadCloser.init(&mock);

    var buf: [8]u8 = undefined;
    const n = try rc.read(&buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);

    rc.close();
    try std.testing.expect(mock.closed);
}
