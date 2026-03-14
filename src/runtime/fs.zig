//! Runtime FS Contract

pub const OpenMode = enum {
    read,
    write,
    read_write,
};

pub const Error = error{
    NotFound,
    PermissionDenied,
    IoError,
    NoSpace,
    InvalidPath,
};

/// Runtime file handle.
pub const File = struct {
    data: ?[]const u8 = null,
    ctx: *anyopaque,
    readFn: ?*const fn (ctx: *anyopaque, buf: []u8) Error!usize = null,
    writeFn: ?*const fn (ctx: *anyopaque, buf: []const u8) Error!usize = null,
    closeFn: *const fn (ctx: *anyopaque) void,
    size: u32,

    pub fn read(self: *File, buf: []u8) Error!usize {
        const f = self.readFn orelse return Error.PermissionDenied;
        return f(self.ctx, buf);
    }

    pub fn write(self: *File, buf: []const u8) Error!usize {
        const f = self.writeFn orelse return Error.PermissionDenied;
        return f(self.ctx, buf);
    }

    pub fn close(self: *File) void {
        self.closeFn(self.ctx);
    }

    pub fn readAll(self: *File, buf: []u8) Error![]const u8 {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try self.read(buf[total..]);
            if (n == 0) break;
            total += n;
        }
        return buf[0..total];
    }
};

/// FS contract:
/// - `open(self: *Impl, path: []const u8, mode: OpenMode) -> ?File`
pub fn from(comptime Impl: type) type {
    comptime {
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };

        _ = @as(*const fn (*BaseType, []const u8, OpenMode) ?File, &BaseType.open);
    }
    return Impl;
}
