const glib = @import("glib");
const heap = @import("../heap.zig");
const std = @import("std");

const fs = glib.fs;

const path_max = 128;
const lfs_flash: c_int = 2;

const o_rdonly: c_int = 0;
const o_wronly: c_int = 1;
const o_rdwr: c_int = 2;
const o_excl: c_int = 0x0008;
const o_append: c_int = 0x0100;
const o_creat: c_int = 0x0200;
const o_trunc: c_int = 0x0400;

const seek_set: c_int = 0;
const seek_cur: c_int = 1;
const seek_end: c_int = 2;

const FlashPart = extern struct {
    start_addr: u32,
    size: u32,
};

const LittleFsPartition = extern struct {
    part_type: c_int,
    mount_path: [*c]const u8,
    part_flash: FlashPart,
};

extern fn bk_vfs_init() c_int;
extern fn bk_vfs_mount(source: [*:0]const u8, target: [*:0]const u8, fs_type: [*:0]const u8, mount_flags: c_ulong, data: ?*const anyopaque) c_int;
extern fn bk_vfs_open(path: [*:0]const u8, flags: c_int) c_int;
extern fn bk_vfs_read(fd: c_int, buf: ?*anyopaque, count: usize) isize;
extern fn bk_vfs_write(fd: c_int, buf: ?*const anyopaque, count: usize) isize;
extern fn bk_vfs_lseek(fd: c_int, offset: c_long, whence: c_int) c_long;
extern fn bk_vfs_fsync(fd: c_int) c_int;
extern fn bk_vfs_close(fd: c_int) c_int;
extern fn bk_vfs_unlink(path: [*:0]const u8) c_int;
extern fn bk_vfs_mkdir(path: [*:0]const u8, mode: c_uint) c_int;

pub const MountError = error{
    Unexpected,
};

pub fn mountLittlefs(comptime Board: type) MountError!void {
    if (bk_vfs_init() != 0) return error.Unexpected;

    const mount_path: [:0]const u8 = Board.littlefs_mount_path;
    var partition = LittleFsPartition{
        .part_type = lfs_flash,
        .mount_path = mount_path.ptr,
        .part_flash = .{
            .start_addr = Board.littlefs_offset,
            .size = Board.littlefs_size_bytes,
        },
    };
    if (bk_vfs_mount("SOURCE_NONE", mount_path, "littlefs", 0, &partition) != 0) return error.Unexpected;
}

pub fn unmountLittlefs(comptime Board: type) void {
    _ = Board;
}

pub const impl = struct {
    pub fn openFile(path: []const u8, options: fs.OpenOptions) fs.OpenFileError!fs.File {
        const flags = switch (options.mode) {
            .read_only => o_rdonly,
            .write_only => o_wronly,
            .read_write => o_rdwr,
        };
        const fd = (open(path, flags) catch |err| switch (err) {
            error.NameTooLong => return error.NameTooLong,
            error.Unexpected => return error.Unexpected,
        }) orelse return error.NotFound;
        return wrap(fd) catch |err| {
            _ = bk_vfs_close(fd);
            return err;
        };
    }

    pub fn createFile(path: []const u8, options: fs.CreateOptions) fs.CreateFileError!fs.File {
        if (options.exclusive) {
            if (open(path, o_rdonly) catch |err| switch (err) {
                error.NameTooLong => return error.NameTooLong,
                error.Unexpected => return error.Unexpected,
            }) |existing| {
                _ = bk_vfs_close(existing);
                return error.AlreadyExists;
            }
        }

        var flags: c_int = if (options.read) o_rdwr else o_wronly;
        flags |= o_creat;
        if (options.truncate) {
            flags |= o_trunc;
        } else {
            flags |= o_append;
        }
        if (options.exclusive) flags |= o_excl;

        const fd = (open(path, flags) catch |err| switch (err) {
            error.NameTooLong => return error.NameTooLong,
            error.Unexpected => return error.Unexpected,
        }) orelse return error.Unexpected;
        return wrap(fd) catch |err| {
            _ = bk_vfs_close(fd);
            return err;
        };
    }

    pub fn deleteFile(path: []const u8) fs.DeleteFileError!void {
        var path_buf: [path_max:0]u8 = undefined;
        const c_path = pathZ(path, &path_buf) catch return error.Unexpected;
        if (bk_vfs_unlink(c_path) != 0) return error.NotFound;
    }

    pub fn makeDir(path: []const u8) fs.MakeDirError!void {
        var path_buf: [path_max:0]u8 = undefined;
        const c_path = pathZ(path, &path_buf) catch return error.NameTooLong;
        if (bk_vfs_mkdir(c_path, 0o755) != 0) return error.Unexpected;
    }

    pub fn stat(path: []const u8) fs.StatError!fs.Stat {
        const fd = (open(path, o_rdonly) catch return error.Unexpected) orelse return error.NotFound;
        defer _ = bk_vfs_close(fd);

        const pos = bk_vfs_lseek(fd, 0, seek_end);
        if (pos < 0) return error.Unexpected;
        return .{
            .size = @intCast(pos),
            .kind = .file,
        };
    }
};

fn open(path: []const u8, flags: c_int) error{ NameTooLong, Unexpected }!?c_int {
    var path_buf: [path_max:0]u8 = undefined;
    const c_path = try pathZ(path, &path_buf);
    const fd = bk_vfs_open(c_path, flags);
    if (fd < 0) return null;
    return fd;
}

fn wrap(fd: c_int) error{OutOfMemory}!fs.File {
    const file = heap.allocator.create(BkFile) catch return error.OutOfMemory;
    file.* = .{ .fd = fd };
    return fs.File.init(file);
}

fn pathZ(path: []const u8, buf: *[path_max:0]u8) error{NameTooLong}![*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0].ptr;
}

const BkFile = struct {
    fd: ?c_int,

    pub fn read(self: *@This(), buf: []u8) fs.File.ReadError!usize {
        const fd = self.fd orelse return error.Unexpected;
        if (buf.len == 0) return 0;
        const n = bk_vfs_read(fd, buf.ptr, buf.len);
        if (n < 0) return error.Unexpected;
        return @intCast(n);
    }

    pub fn write(self: *@This(), data: []const u8) fs.File.WriteError!usize {
        const fd = self.fd orelse return error.Unexpected;
        if (data.len == 0) return 0;
        const n = bk_vfs_write(fd, data.ptr, data.len);
        if (n < 0) return error.Unexpected;
        return @intCast(n);
    }

    pub fn seek(self: *@This(), offset: i64, whence: fs.SeekWhence) fs.File.SeekError!u64 {
        const fd = self.fd orelse return error.Unexpected;
        const c_offset = castOffset(offset) orelse return error.Unexpected;
        const c_whence: c_int = switch (whence) {
            .start => seek_set,
            .current => seek_cur,
            .end => seek_end,
        };
        const pos = bk_vfs_lseek(fd, c_offset, c_whence);
        if (pos < 0) return error.Unexpected;
        return @intCast(pos);
    }

    pub fn sync(self: *@This()) fs.File.SyncError!void {
        const fd = self.fd orelse return error.Unexpected;
        if (bk_vfs_fsync(fd) != 0) return error.Unexpected;
    }

    pub fn close(self: *@This()) void {
        if (self.fd) |fd| {
            _ = bk_vfs_close(fd);
            self.fd = null;
        }
    }

    pub fn deinit(self: *@This()) void {
        heap.allocator.destroy(self);
    }
};

fn castOffset(offset: i64) ?c_long {
    if (offset < std.math.minInt(c_long) or offset > std.math.maxInt(c_long)) return null;
    return @intCast(offset);
}
