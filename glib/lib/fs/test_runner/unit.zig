const fs_mod = @import("../../fs.zig");
const builtin_std = @import("std");
const testing_api = @import("testing");

pub fn make(comptime std: type, comptime fs: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("File/vtable", FileVTableRunner(std));
            t.run("namespace/read_write_delete", NamespaceRunner(std, fs));
            t.run("namespace/stream_read_write_seek", StreamingRunner(std, fs));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

fn FileVTableRunner(comptime std: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            var mem = MemoryFile{};
            const file = fs_mod.File.init(&mem);

            _ = file.write("abc") catch |err| return fail(t, err);
            _ = file.seek(0, .start) catch |err| return fail(t, err);

            var buf: [3]u8 = undefined;
            const n = file.read(&buf) catch |err| return fail(t, err);
            if (!expect(std, t, std.mem.eql(u8, buf[0..n], "abc"))) return false;

            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

fn NamespaceRunner(comptime std: type, comptime fs: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), alloc: std.mem.Allocator) !void {
            _ = self;
            _ = alloc;
        }

        pub fn run(self: *@This(), t: *testing_api.T, alloc: std.mem.Allocator) bool {
            _ = self;

            const path = comptime builtin_std.fmt.comptimePrint("glib-fs-unit-{x}.tmp", .{
                builtin_std.hash.Wyhash.hash(0, @typeName(fs)),
            });
            fs.deleteFile(path) catch {};
            defer fs.deleteFile(path) catch {};

            fs.writeFile(path, "hello fs") catch |err| return fail(t, err);

            const stat = fs.stat(path) catch |err| return fail(t, err);
            if (!expect(std, t, stat.size == 8)) return false;

            const data = fs.readFileAlloc(alloc, path, 64) catch |err| return fail(t, err);
            defer alloc.free(data);
            if (!expect(std, t, std.mem.eql(u8, data, "hello fs"))) return false;

            fs.deleteFile(path) catch |err| return fail(t, err);
            if (fs.openFile(path, .{})) |file| {
                file.deinit();
                t.logFatal("expected NotFound");
                return false;
            } else |err| switch (err) {
                error.NotFound => {},
                else => return fail(t, err),
            }

            return true;
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            _ = self;
            _ = alloc;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

fn StreamingRunner(comptime std: type, comptime fs: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), alloc: std.mem.Allocator) !void {
            _ = self;
            _ = alloc;
        }

        pub fn run(self: *@This(), t: *testing_api.T, alloc: std.mem.Allocator) bool {
            _ = self;
            _ = alloc;

            const payload = "streamed glib fs payload across small chunks";
            const path = comptime builtin_std.fmt.comptimePrint("glib-fs-stream-unit-{x}.tmp", .{
                builtin_std.hash.Wyhash.hash(0, @typeName(fs)),
            });
            fs.deleteFile(path) catch {};
            defer fs.deleteFile(path) catch {};

            var file = fs.createFile(path, .{
                .read = true,
                .truncate = true,
                .exclusive = false,
            }) catch |err| return fail(t, err);
            defer file.deinit();

            inline for (.{
                "streamed ",
                "glib ",
                "fs ",
                "payload ",
                "across ",
                "small ",
                "chunks",
            }) |chunk| {
                var written: usize = 0;
                while (written < chunk.len) {
                    const n = file.write(chunk[written..]) catch |err| return fail(t, err);
                    if (!expect(std, t, n != 0)) return false;
                    written += n;
                }
            }
            file.sync() catch |err| return fail(t, err);

            const pos = file.seek(0, .start) catch |err| return fail(t, err);
            if (!expect(std, t, pos == 0)) return false;

            var data: [payload.len]u8 = undefined;
            var total: usize = 0;
            var scratch: [5]u8 = undefined;
            while (total < data.len) {
                const read_len = @min(scratch.len, data.len - total);
                const n = file.read(scratch[0..read_len]) catch |err| return fail(t, err);
                if (!expect(std, t, n != 0)) return false;
                @memcpy(data[total..][0..n], scratch[0..n]);
                total += n;
            }
            if (!expect(std, t, std.mem.eql(u8, &data, payload))) return false;

            const eof = file.read(&scratch) catch |err| return fail(t, err);
            if (!expect(std, t, eof == 0)) return false;

            return true;
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            _ = self;
            _ = alloc;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

fn expect(comptime std: type, t: *testing_api.T, condition: bool) bool {
    std.testing.expect(condition) catch |err| return fail(t, err);
    return true;
}

fn fail(t: *testing_api.T, err: anyerror) bool {
    t.logFatal(@errorName(err));
    return false;
}

const MemoryFile = struct {
    buf: [16]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,
    closed: bool = false,

    pub fn read(self: *@This(), out: []u8) fs_mod.File.ReadError!usize {
        if (self.closed) return error.Unexpected;
        const n = @min(out.len, self.len - self.pos);
        @memcpy(out[0..n], self.buf[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    pub fn write(self: *@This(), data: []const u8) fs_mod.File.WriteError!usize {
        if (self.closed) return error.Unexpected;
        const n = @min(data.len, self.buf.len - self.pos);
        @memcpy(self.buf[self.pos..][0..n], data[0..n]);
        self.pos += n;
        self.len = @max(self.len, self.pos);
        return n;
    }

    pub fn seek(self: *@This(), offset: i64, whence: fs_mod.SeekWhence) fs_mod.File.SeekError!u64 {
        const base: i64 = switch (whence) {
            .start => 0,
            .current => @intCast(self.pos),
            .end => @intCast(self.len),
        };
        const next = base + offset;
        if (next < 0 or next > self.buf.len) return error.Unexpected;
        self.pos = @intCast(next);
        return self.pos;
    }

    pub fn sync(self: *@This()) fs_mod.File.SyncError!void {
        _ = self;
    }

    pub fn close(self: *@This()) void {
        self.closed = true;
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};
