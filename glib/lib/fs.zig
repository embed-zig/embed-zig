//! fs — runtime-bound portable filesystem namespace.

const builtin_std = @import("std");
const testing_api = @import("testing");

pub const File = @import("fs/File.zig");
pub const SeekWhence = File.SeekWhence;

pub const OpenMode = enum {
    read_only,
    write_only,
    read_write,
};

pub const OpenOptions = struct {
    mode: OpenMode = .read_only,
};

pub const CreateOptions = struct {
    read: bool = false,
    truncate: bool = true,
    exclusive: bool = false,
};

pub const FileType = enum {
    file,
    directory,
    other,
    unknown,
};

pub const Stat = struct {
    size: u64 = 0,
    kind: FileType = .unknown,
};

pub const OpenFileError = error{
    NotFound,
    AccessDenied,
    IsDir,
    NameTooLong,
    Unsupported,
    OutOfMemory,
    Unexpected,
};

pub const CreateFileError = error{
    AccessDenied,
    AlreadyExists,
    NameTooLong,
    NoSpaceLeft,
    Unsupported,
    OutOfMemory,
    Unexpected,
};

pub const DeleteFileError = error{
    NotFound,
    AccessDenied,
    Unsupported,
    Unexpected,
};

pub const MakeDirError = error{
    AlreadyExists,
    NotFound,
    AccessDenied,
    NameTooLong,
    Unsupported,
    Unexpected,
};

pub const StatError = error{
    NotFound,
    AccessDenied,
    Unsupported,
    Unexpected,
};

pub const ReadFileAllocError = OpenFileError || File.ReadError || builtin_std.mem.Allocator.Error || error{
    FileTooBig,
};

pub const WriteFileError = CreateFileError || File.WriteError || File.SyncError;

pub const unsupported_impl = struct {
    pub fn openFile(path: []const u8, options: OpenOptions) OpenFileError!File {
        _ = path;
        _ = options;
        return error.Unsupported;
    }

    pub fn createFile(path: []const u8, options: CreateOptions) CreateFileError!File {
        _ = path;
        _ = options;
        return error.Unsupported;
    }

    pub fn deleteFile(path: []const u8) DeleteFileError!void {
        _ = path;
        return error.Unsupported;
    }

    pub fn makeDir(path: []const u8) MakeDirError!void {
        _ = path;
        return error.Unsupported;
    }

    pub fn stat(path: []const u8) StatError!Stat {
        _ = path;
        return error.Unsupported;
    }
};

pub fn make(comptime std: type, comptime impl: type) type {
    comptime validateImpl(impl);

    return struct {
        pub const File = @import("fs.zig").File;
        pub const SeekWhence = @import("fs.zig").SeekWhence;
        pub const OpenMode = @import("fs.zig").OpenMode;
        pub const OpenOptions = @import("fs.zig").OpenOptions;
        pub const CreateOptions = @import("fs.zig").CreateOptions;
        pub const FileType = @import("fs.zig").FileType;
        pub const Stat = @import("fs.zig").Stat;

        pub fn openFile(path: []const u8, options: @import("fs.zig").OpenOptions) OpenFileError!@import("fs.zig").File {
            return impl.openFile(path, options);
        }

        pub fn createFile(path: []const u8, options: @import("fs.zig").CreateOptions) CreateFileError!@import("fs.zig").File {
            return impl.createFile(path, options);
        }

        pub fn deleteFile(path: []const u8) DeleteFileError!void {
            return impl.deleteFile(path);
        }

        pub fn makeDir(path: []const u8) MakeDirError!void {
            return impl.makeDir(path);
        }

        pub fn stat(path: []const u8) StatError!@import("fs.zig").Stat {
            return impl.stat(path);
        }

        pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ReadFileAllocError![]u8 {
            if (stat(path)) |info| {
                const size = builtin_std.math.cast(usize, info.size) orelse return error.FileTooBig;
                if (size > max_bytes) return error.FileTooBig;

                var file = try openFile(path, .{ .mode = .read_only });
                defer file.deinit();

                var bytes = try allocator.alloc(u8, size);
                errdefer allocator.free(bytes);
                var len: usize = 0;
                while (len < bytes.len) {
                    const n = try file.read(bytes[len..]);
                    if (n == 0) break;
                    len += n;
                }
                if (len == bytes.len) return bytes;
                return allocator.realloc(bytes, len);
            } else |_| {}

            var file = try openFile(path, .{ .mode = .read_only });
            defer file.deinit();

            var bytes = try allocator.alloc(u8, @min(max_bytes, 4096));
            errdefer allocator.free(bytes);
            var len: usize = 0;
            var scratch: [4096]u8 = undefined;

            while (true) {
                const n = try file.read(&scratch);
                if (n == 0) break;
                if (len + n > max_bytes) return error.FileTooBig;
                if (len + n > bytes.len) {
                    var next_capacity = @max(bytes.len, 1);
                    while (next_capacity < len + n) {
                        next_capacity = @min(max_bytes, next_capacity * 2);
                    }
                    bytes = try allocator.realloc(bytes, next_capacity);
                }
                @memcpy(bytes[len..][0..n], scratch[0..n]);
                len += n;
            }

            return allocator.realloc(bytes, len);
        }

        pub fn writeFile(path: []const u8, data: []const u8) WriteFileError!void {
            var file = try createFile(path, .{ .read = false, .truncate = true, .exclusive = false });
            defer file.deinit();

            var written: usize = 0;
            while (written < data.len) {
                const n = try file.write(data[written..]);
                if (n == 0) return error.Unexpected;
                written += n;
            }
            try file.sync();
        }
    };
}

fn validateImpl(comptime impl: type) void {
    const expected = struct {
        fn openFile(_: []const u8, _: OpenOptions) OpenFileError!File {
            unreachable;
        }
        fn createFile(_: []const u8, _: CreateOptions) CreateFileError!File {
            unreachable;
        }
        fn deleteFile(_: []const u8) DeleteFileError!void {
            unreachable;
        }
        fn makeDir(_: []const u8) MakeDirError!void {
            unreachable;
        }
        fn stat(_: []const u8) StatError!Stat {
            unreachable;
        }
    };

    if (!@hasDecl(impl, "openFile") or @TypeOf(impl.openFile) != @TypeOf(expected.openFile))
        @compileError("fs impl must expose openFile([]const u8, OpenOptions) OpenFileError!File");
    if (!@hasDecl(impl, "createFile") or @TypeOf(impl.createFile) != @TypeOf(expected.createFile))
        @compileError("fs impl must expose createFile([]const u8, CreateOptions) CreateFileError!File");
    if (!@hasDecl(impl, "deleteFile") or @TypeOf(impl.deleteFile) != @TypeOf(expected.deleteFile))
        @compileError("fs impl must expose deleteFile([]const u8) DeleteFileError!void");
    if (!@hasDecl(impl, "makeDir") or @TypeOf(impl.makeDir) != @TypeOf(expected.makeDir))
        @compileError("fs impl must expose makeDir([]const u8) MakeDirError!void");
    if (!@hasDecl(impl, "stat") or @TypeOf(impl.stat) != @TypeOf(expected.stat))
        @compileError("fs impl must expose stat([]const u8) StatError!Stat");
}

pub const test_runner = struct {
    pub const unit = @import("fs/test_runner/unit.zig");
};
