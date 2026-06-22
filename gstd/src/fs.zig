const builtin_std = @import("std");
const glib = @import("glib");

const fs = glib.fs;
const host_allocator = builtin_std.heap.page_allocator;
const log = builtin_std.log.scoped(.gstd_fs);

const HostMount = struct {
    prefix: []const u8,
    host_root: []const u8,
};

const max_host_mounts = 8;
var host_mounts: [max_host_mounts]HostMount = undefined;
var host_mount_count: usize = 0;

pub fn setHostMount(prefix: []const u8, host_root: []const u8) void {
    for (host_mounts[0..host_mount_count]) |*mount| {
        if (builtin_std.mem.eql(u8, mount.prefix, prefix)) {
            mount.host_root = host_root;
            return;
        }
    }
    if (host_mount_count >= max_host_mounts) {
        log.warn("host mount table full; ignoring mount {s} -> {s}", .{ prefix, host_root });
        return;
    }
    host_mounts[host_mount_count] = .{ .prefix = prefix, .host_root = host_root };
    host_mount_count += 1;
}

pub const impl = struct {
    pub fn openFile(path: []const u8, options: fs.OpenOptions) fs.OpenFileError!fs.File {
        const resolved = resolvePath(path) catch |err| return resolveOpenCreateError(err);
        defer resolved.deinit();

        const file = openHostFile(resolved.path, .{
            .mode = switch (options.mode) {
                .read_only => .read_only,
                .write_only => .write_only,
                .read_write => .read_write,
            },
        }) catch |err| return mapOpenError(err);

        const host_file = builtin_std.heap.page_allocator.create(HostFile) catch return error.OutOfMemory;
        host_file.* = .{ .file = file };
        return fs.File.init(host_file);
    }

    pub fn createFile(path: []const u8, options: fs.CreateOptions) fs.CreateFileError!fs.File {
        const resolved = resolvePath(path) catch |err| return resolveOpenCreateError(err);
        defer resolved.deinit();

        const file = createHostFile(resolved.path, .{
            .read = options.read,
            .truncate = options.truncate,
            .exclusive = options.exclusive,
        }) catch |err| return mapCreateError(err);

        const host_file = builtin_std.heap.page_allocator.create(HostFile) catch return error.OutOfMemory;
        host_file.* = .{ .file = file };
        return fs.File.init(host_file);
    }

    pub fn deleteFile(path: []const u8) fs.DeleteFileError!void {
        const resolved = resolvePath(path) catch |err| return resolveBasicError(err);
        defer resolved.deinit();

        deleteHostFile(resolved.path) catch |err| return mapDeleteError(err);
    }

    pub fn makeDir(path: []const u8) fs.MakeDirError!void {
        const resolved = resolvePath(path) catch |err| return resolveBasicError(err);
        defer resolved.deinit();

        makeHostDir(resolved.path) catch |err| return mapMakeDirError(err);
    }

    pub fn stat(path: []const u8) fs.StatError!fs.Stat {
        const resolved = resolvePath(path) catch |err| return resolveBasicError(err);
        defer resolved.deinit();

        const file_stat = statHostFile(resolved.path) catch |err| return mapStatError(err);
        return .{
            .size = file_stat.size,
            .kind = switch (file_stat.kind) {
                .file => .file,
                .directory => .directory,
                else => .other,
            },
        };
    }
};

const ResolvedPath = struct {
    path: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: @This()) void {
        if (self.owned) |owned| host_allocator.free(owned);
    }
};

fn resolvePath(path: []const u8) error{ AccessDenied, OutOfMemory }!ResolvedPath {
    var best_mount: ?HostMount = null;
    for (host_mounts[0..host_mount_count]) |mount| {
        if (mountMatches(path, mount.prefix)) {
            if (best_mount == null or mount.prefix.len > best_mount.?.prefix.len) {
                best_mount = mount;
            }
        }
    }
    if (best_mount) |mount| {
        const suffix = if (path.len == mount.prefix.len)
            ""
        else
            path[mount.prefix.len + 1 ..];
        if (suffix.len > 0 and suffix[0] == '/') return error.AccessDenied;
        if (hasParentComponent(suffix)) return error.AccessDenied;
        const resolved = if (suffix.len == 0)
            try host_allocator.dupe(u8, mount.host_root)
        else
            try builtin_std.fs.path.join(host_allocator, &.{ mount.host_root, suffix });
        return .{
            .path = resolved,
            .owned = resolved,
        };
    }

    return .{ .path = path };
}

fn mountMatches(path: []const u8, prefix: []const u8) bool {
    if (!builtin_std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

fn hasParentComponent(path: []const u8) bool {
    var rest = path;
    while (rest.len > 0) {
        const slash = builtin_std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        if (builtin_std.mem.eql(u8, rest[0..slash], "..")) return true;
        if (slash == rest.len) return false;
        rest = rest[slash + 1 ..];
    }
    return false;
}

fn resolveOpenCreateError(err: error{ AccessDenied, OutOfMemory }) error{ AccessDenied, OutOfMemory } {
    return switch (err) {
        error.AccessDenied => error.AccessDenied,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn resolveBasicError(err: error{ AccessDenied, OutOfMemory }) error{ AccessDenied, Unexpected } {
    return switch (err) {
        error.AccessDenied => error.AccessDenied,
        error.OutOfMemory => error.Unexpected,
    };
}

fn openHostFile(path: []const u8, flags: builtin_std.fs.File.OpenFlags) !builtin_std.fs.File {
    if (builtin_std.fs.path.isAbsolute(path)) {
        return builtin_std.fs.openFileAbsolute(path, flags);
    }
    return builtin_std.fs.cwd().openFile(path, flags);
}

fn createHostFile(path: []const u8, flags: builtin_std.fs.File.CreateFlags) !builtin_std.fs.File {
    if (builtin_std.fs.path.isAbsolute(path)) {
        return builtin_std.fs.createFileAbsolute(path, flags);
    }
    return builtin_std.fs.cwd().createFile(path, flags);
}

fn deleteHostFile(path: []const u8) !void {
    if (builtin_std.fs.path.isAbsolute(path)) {
        return builtin_std.fs.deleteFileAbsolute(path);
    }
    return builtin_std.fs.cwd().deleteFile(path);
}

fn makeHostDir(path: []const u8) !void {
    if (builtin_std.fs.path.isAbsolute(path)) {
        return builtin_std.fs.makeDirAbsolute(path);
    }
    return builtin_std.fs.cwd().makeDir(path);
}

fn statHostFile(path: []const u8) !builtin_std.fs.File.Stat {
    if (builtin_std.fs.path.isAbsolute(path)) {
        var file = try builtin_std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return file.stat();
    }
    return builtin_std.fs.cwd().statFile(path);
}

const HostFile = struct {
    file: ?builtin_std.fs.File,

    pub fn read(self: *@This(), buf: []u8) fs.File.ReadError!usize {
        const file = self.file orelse return error.Unexpected;
        return file.read(buf) catch error.Unexpected;
    }

    pub fn write(self: *@This(), data: []const u8) fs.File.WriteError!usize {
        const file = self.file orelse return error.Unexpected;
        return file.write(data) catch |err| switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.NoSpaceLeft => error.NoSpaceLeft,
            else => error.Unexpected,
        };
    }

    pub fn seek(self: *@This(), offset: i64, whence: fs.SeekWhence) fs.File.SeekError!u64 {
        const file = self.file orelse return error.Unexpected;
        switch (whence) {
            .start => {
                if (offset < 0) return error.Unexpected;
                file.seekTo(@intCast(offset)) catch return error.Unexpected;
            },
            .current => file.seekBy(offset) catch return error.Unexpected,
            .end => file.seekFromEnd(offset) catch return error.Unexpected,
        }
        return file.getPos() catch error.Unexpected;
    }

    pub fn sync(self: *@This()) fs.File.SyncError!void {
        const file = self.file orelse return error.Unexpected;
        file.sync() catch return error.Unexpected;
    }

    pub fn close(self: *@This()) void {
        if (self.file) |file| {
            file.close();
            self.file = null;
        }
    }

    pub fn deinit(self: *@This()) void {
        builtin_std.heap.page_allocator.destroy(self);
    }
};

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn replacesExistingHostMount() !void {
            resetHostMountsForTest();
            defer resetHostMountsForTest();

            setHostMount("/storage", "/tmp/first");
            setHostMount("/storage", "/tmp/second");

            const resolved = try resolvePath("/storage/app.db");
            defer resolved.deinit();

            try grt.std.testing.expectEqualStrings("/tmp/second/app.db", resolved.path);
        }

        fn prefersLongestMatchingHostMount() !void {
            resetHostMountsForTest();
            defer resetHostMountsForTest();

            setHostMount("/storage", "/tmp/storage");
            setHostMount("/storage/cache", "/tmp/cache");

            const resolved = try resolvePath("/storage/cache/image.bin");
            defer resolved.deinit();

            try grt.std.testing.expectEqualStrings("/tmp/cache/image.bin", resolved.path);
        }

        fn rejectsParentTraversalInsideHostMount() !void {
            resetHostMountsForTest();
            defer resetHostMountsForTest();

            setHostMount("/storage", "/tmp/storage");

            try grt.std.testing.expectError(error.AccessDenied, resolvePath("/storage/../outside"));
            try grt.std.testing.expectError(error.AccessDenied, resolvePath("/storage/nested/../outside"));
            try grt.std.testing.expectError(error.AccessDenied, resolvePath("/storage//outside"));
        }

        fn resetHostMountsForTest() void {
            host_mount_count = 0;
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.replacesExistingHostMount() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.prefersLongestMatchingHostMount() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rejectsParentTraversalInsideHostMount() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

fn mapOpenError(err: anyerror) fs.OpenFileError {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied => error.AccessDenied,
        error.IsDir => error.IsDir,
        error.NameTooLong => error.NameTooLong,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unexpected,
    };
}

fn mapCreateError(err: anyerror) fs.CreateFileError {
    return switch (err) {
        error.PathAlreadyExists => error.AlreadyExists,
        error.AccessDenied => error.AccessDenied,
        error.NameTooLong => error.NameTooLong,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unexpected,
    };
}

fn mapDeleteError(err: anyerror) fs.DeleteFileError {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied => error.AccessDenied,
        else => error.Unexpected,
    };
}

fn mapMakeDirError(err: anyerror) fs.MakeDirError {
    return switch (err) {
        error.PathAlreadyExists => error.AlreadyExists,
        error.FileNotFound => error.NotFound,
        error.AccessDenied => error.AccessDenied,
        error.NameTooLong => error.NameTooLong,
        else => error.Unexpected,
    };
}

fn mapStatError(err: anyerror) fs.StatError {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied => error.AccessDenied,
        else => error.Unexpected,
    };
}
