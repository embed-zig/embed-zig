const std = @import("std");
const esp = @import("esp");
const runtime = @import("runtime");

const posix = esp.newlib.fs;
const FsError = runtime.fs.Error;
const OpenMode = runtime.fs.OpenMode;
const File = runtime.fs.File;

pub const Fs = struct {
    const FileCtx = struct {
        fd: i32,
    };

    pub fn open(_: *@This(), path: []const u8, mode: OpenMode) ?File {
        var path_buf: [256:0]u8 = undefined;
        if (path.len >= path_buf.len) return null;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const cpath: [*:0]const u8 = &path_buf;

        const flags: i32 = switch (mode) {
            .read => posix.O_RDONLY,
            .write => posix.O_WRONLY | posix.O_CREAT | posix.O_TRUNC,
            .read_write => posix.O_RDWR | posix.O_CREAT,
        };

        const fd = posix.openFile(cpath, flags) catch return null;

        const ctx = std.heap.page_allocator.create(FileCtx) catch {
            posix.closeFile(fd);
            return null;
        };
        ctx.* = .{ .fd = fd };

        return File{
            .ctx = @ptrCast(ctx),
            .readFn = switch (mode) {
                .write => null,
                else => &readFn,
            },
            .writeFn = switch (mode) {
                .read => null,
                else => &writeFn,
            },
            .closeFn = &closeFn,
            .size = posix.fileSize(fd) catch 0,
        };
    }

    fn readFn(ctx_ptr: *anyopaque, buf: []u8) FsError!usize {
        const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
        return posix.readFile(ctx.fd, buf) catch return FsError.IoError;
    }

    fn writeFn(ctx_ptr: *anyopaque, buf: []const u8) FsError!usize {
        const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
        return posix.writeFile(ctx.fd, buf) catch return FsError.IoError;
    }

    fn closeFn(ctx_ptr: *anyopaque) void {
        const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
        posix.closeFile(ctx.fd);
        std.heap.page_allocator.destroy(ctx);
    }
};
