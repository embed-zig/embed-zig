const glib = @import("glib");
const std = @import("std");
const heap = @import("esp_heap");
const build_config = @import("build_config");
const heap_binding = @import("std/heap/binding.zig");
const thread_binding = @import("std/thread/binding.zig");

const fs = glib.fs;
const allocator = heap.Allocator(.{ .caps = .internal_8bit });

const CFile = opaque {};

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*CFile;
extern fn fread(ptr: *anyopaque, size: usize, count: usize, stream: *CFile) usize;
extern fn fwrite(ptr: *const anyopaque, size: usize, count: usize, stream: *CFile) usize;
extern fn fseek(stream: *CFile, offset: c_long, whence: c_int) c_int;
extern fn ftell(stream: *CFile) c_long;
extern fn fflush(stream: *CFile) c_int;
extern fn fclose(stream: *CFile) c_int;
extern fn remove(path: [*:0]const u8) c_int;
extern fn mkdir(path: [*:0]const u8, mode: c_int) c_int;
extern fn esp_vfs_spiffs_register(conf: *const SpiffsConf) c_int;
extern fn esp_vfs_spiffs_unregister(partition_label: [*:0]const u8) c_int;

const seek_set: c_int = 0;
const seek_cur: c_int = 1;
const seek_end: c_int = 2;
const assets_partition_label = "assets";
const assets_mount_path = "/assets";
const storage_partition_label = "storage";
const storage_mount_path = "/storage";
const worker_stack_size = 12 * 1024;
const worker_priority = 7;
const worker_core_id: i32 = 0;
const worker_queue_len = 8;
const worker_uninitialized: usize = 0;
const worker_initializing: usize = 1;

var worker_queue_bits = glib.std.atomic.Value(usize).init(worker_uninitialized);
var worker_handle: thread_binding.Handle = null;

const SpiffsConf = extern struct {
    base_path: [*:0]const u8,
    partition_label: ?[*:0]const u8,
    max_files: usize,
    format_if_mount_failed: bool,
};

pub const MountError = error{
    Unexpected,
};

pub fn mountAssets() MountError!void {
    if (!hasAssetsSpiffsPartition()) return;
    try mountSpiffsPartition(assets_partition_label, assets_mount_path, .{
        .max_files = 16,
        .format_if_mount_failed = false,
    });
}

pub fn unmountAssets() void {
    if (!hasAssetsSpiffsPartition()) return;
    var label_buf: [256:0]u8 = undefined;
    const c_partition_label = pathZ(assets_partition_label, &label_buf) catch return;
    _ = esp_vfs_spiffs_unregister(c_partition_label);
}

pub fn hasAssetsPartition() bool {
    return hasAssetsSpiffsPartition();
}

pub fn mountStorage() MountError!void {
    if (!hasStorageSpiffsPartition()) return;
    try mountSpiffsPartition(storage_partition_label, storage_mount_path, .{
        .max_files = 16,
        .format_if_mount_failed = true,
    });
}

pub fn unmountStorage() void {
    if (!hasStorageSpiffsPartition()) return;
    var label_buf: [256:0]u8 = undefined;
    const c_partition_label = pathZ(storage_partition_label, &label_buf) catch return;
    _ = esp_vfs_spiffs_unregister(c_partition_label);
}

pub fn hasStoragePartition() bool {
    return hasStorageSpiffsPartition();
}

pub const MountOptions = struct {
    max_files: usize = 8,
    format_if_mount_failed: bool = false,
};

pub fn mountSpiffsPartition(
    partition_label: []const u8,
    base_path: []const u8,
    options: MountOptions,
) MountError!void {
    var label_buf: [256:0]u8 = undefined;
    var base_buf: [256:0]u8 = undefined;
    const c_partition_label = pathZ(partition_label, &label_buf) catch return error.Unexpected;
    const c_base_path = pathZ(base_path, &base_buf) catch return error.Unexpected;
    const conf: SpiffsConf = .{
        .base_path = c_base_path,
        .partition_label = c_partition_label,
        .max_files = options.max_files,
        .format_if_mount_failed = options.format_if_mount_failed,
    };
    if (esp_vfs_spiffs_register(&conf) != 0) return error.Unexpected;
}

pub const impl = struct {
    pub fn openFile(path: []const u8, options: fs.OpenOptions) fs.OpenFileError!fs.File {
        if (path.len >= 256) return error.NameTooLong;
        const mode: FileMode = switch (options.mode) {
            .read_only => .rb,
            .write_only, .read_write => .rb_plus,
        };
        const handle = (workerOpen(path, mode) catch return error.Unexpected) orelse return error.NotFound;
        return wrap(handle) catch |err| {
            workerClose(handle);
            return err;
        };
    }

    pub fn createFile(path: []const u8, options: fs.CreateOptions) fs.CreateFileError!fs.File {
        if (path.len >= 256) return error.NameTooLong;

        if (options.exclusive) {
            if ((workerOpen(path, .rb) catch return error.Unexpected)) |existing| {
                workerClose(existing);
                return error.AlreadyExists;
            }
        }

        const mode: FileMode = if (options.truncate)
            if (options.read) .wb_plus else .wb
        else
            .ab_plus;
        const handle = (workerOpen(path, mode) catch return error.Unexpected) orelse return error.Unexpected;
        return wrap(handle) catch |err| {
            workerClose(handle);
            return err;
        };
    }

    pub fn deleteFile(path: []const u8) fs.DeleteFileError!void {
        if (path.len >= 256) return error.Unexpected;
        if ((workerPathOp(.delete_file, path) catch return error.Unexpected) != 0) return error.NotFound;
    }

    pub fn makeDir(path: []const u8) fs.MakeDirError!void {
        if (path.len >= 256) return error.NameTooLong;
        if ((workerPathOp(.make_dir, path) catch return error.Unexpected) != 0) return error.Unexpected;
    }

    pub fn stat(path: []const u8) fs.StatError!fs.Stat {
        if (path.len >= 256) return error.Unexpected;
        const handle = (workerOpen(path, .rb) catch return error.Unexpected) orelse return error.NotFound;
        defer workerClose(handle);

        const end = workerSeek(handle, 0, seek_end) catch return error.Unexpected;
        if (end < 0) return error.Unexpected;

        return .{
            .size = @intCast(end),
            .kind = .file,
        };
    }
};

fn hasAssetsSpiffsPartition() bool {
    return hasNamedSpiffsPartition(assets_partition_label);
}

fn hasStorageSpiffsPartition() bool {
    return hasNamedSpiffsPartition(storage_partition_label);
}

fn hasNamedSpiffsPartition(comptime partition_label: []const u8) bool {
    for (build_config.partition_table.entries) |entry| {
        if (!glib.std.mem.eql(u8, entry.name, partition_label)) continue;
        if (entry.kind != .data) return false;
        switch (entry.subtype) {
            .spiffs => {},
            else => return false,
        }
        const data = entry.data orelse return false;
        switch (data) {
            .spiffs => return true,
            else => return false,
        }
    }
    return false;
}

fn wrap(handle: *CFile) error{OutOfMemory}!fs.File {
    const esp_file = allocator.create(EspFile) catch return error.OutOfMemory;
    esp_file.* = .{ .handle = handle };
    return fs.File.init(esp_file);
}

fn pathZ(path: []const u8, buf: *[256:0]u8) error{NameTooLong}![*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0].ptr;
}

const FileMode = enum {
    rb,
    rb_plus,
    wb,
    wb_plus,
    ab_plus,

    fn text(self: @This()) [*:0]const u8 {
        return switch (self) {
            .rb => "rb",
            .rb_plus => "rb+",
            .wb => "wb",
            .wb_plus => "wb+",
            .ab_plus => "ab+",
        };
    }
};

const WorkerOp = enum {
    open,
    read,
    write,
    seek,
    sync,
    close,
    delete_file,
    make_dir,
};

const WorkerRequest = struct {
    op: WorkerOp,
    done: thread_binding.Handle,
    path: []const u8 = "",
    mode: FileMode = .rb,
    handle: ?*CFile = null,
    buf: []u8 = &.{},
    data: []const u8 = &.{},
    offset: c_long = 0,
    whence: c_int = seek_set,
    bytes: usize = 0,
    pos: c_long = 0,
    rc: c_int = 0,
};

fn workerOpen(path: []const u8, mode: FileMode) error{Unexpected}!?*CFile {
    var request = WorkerRequest{
        .op = .open,
        .done = thread_binding.espz_semaphore_create_binary() orelse return error.Unexpected,
        .path = path,
        .mode = mode,
    };
    defer thread_binding.espz_semaphore_delete(request.done);
    try submitWorkerRequest(&request);
    return request.handle;
}

fn workerRead(handle: *CFile, buf: []u8) error{Unexpected}!usize {
    if (buf.len == 0) return 0;
    var request = WorkerRequest{
        .op = .read,
        .done = thread_binding.espz_semaphore_create_binary() orelse return error.Unexpected,
        .handle = handle,
        .buf = buf,
    };
    defer thread_binding.espz_semaphore_delete(request.done);
    try submitWorkerRequest(&request);
    return request.bytes;
}

fn workerWrite(handle: *CFile, data: []const u8) error{Unexpected}!usize {
    if (data.len == 0) return 0;
    var request = WorkerRequest{
        .op = .write,
        .done = thread_binding.espz_semaphore_create_binary() orelse return error.Unexpected,
        .handle = handle,
        .data = data,
    };
    defer thread_binding.espz_semaphore_delete(request.done);
    try submitWorkerRequest(&request);
    return request.bytes;
}

fn workerSeek(handle: *CFile, offset: c_long, whence: c_int) error{Unexpected}!c_long {
    var request = WorkerRequest{
        .op = .seek,
        .done = thread_binding.espz_semaphore_create_binary() orelse return error.Unexpected,
        .handle = handle,
        .offset = offset,
        .whence = whence,
    };
    defer thread_binding.espz_semaphore_delete(request.done);
    try submitWorkerRequest(&request);
    if (request.rc != 0 or request.pos < 0) return error.Unexpected;
    return request.pos;
}

fn workerSync(handle: *CFile) error{Unexpected}!void {
    var request = WorkerRequest{
        .op = .sync,
        .done = thread_binding.espz_semaphore_create_binary() orelse return error.Unexpected,
        .handle = handle,
    };
    defer thread_binding.espz_semaphore_delete(request.done);
    try submitWorkerRequest(&request);
    if (request.rc != 0) return error.Unexpected;
}

fn workerClose(handle: *CFile) void {
    var request = WorkerRequest{
        .op = .close,
        .done = thread_binding.espz_semaphore_create_binary() orelse return,
        .handle = handle,
    };
    defer thread_binding.espz_semaphore_delete(request.done);
    submitWorkerRequest(&request) catch {};
}

fn workerPathOp(op: WorkerOp, path: []const u8) error{Unexpected}!c_int {
    var request = WorkerRequest{
        .op = op,
        .done = thread_binding.espz_semaphore_create_binary() orelse return error.Unexpected,
        .path = path,
    };
    defer thread_binding.espz_semaphore_delete(request.done);
    try submitWorkerRequest(&request);
    return request.rc;
}

fn submitWorkerRequest(request: *WorkerRequest) error{Unexpected}!void {
    const queue = try ensureWorkerQueue();
    var item = request;
    if (thread_binding.espz_queue_send(queue, @ptrCast(&item), thread_binding.max_delay) != thread_binding.pd_true) {
        return error.Unexpected;
    }
    if (thread_binding.espz_semaphore_take(request.done, thread_binding.max_delay) != thread_binding.pd_true) {
        return error.Unexpected;
    }
}

fn ensureWorkerQueue() error{Unexpected}!thread_binding.Handle {
    while (true) {
        const bits = worker_queue_bits.load(.acquire);
        switch (bits) {
            worker_uninitialized => {
                if (worker_queue_bits.cmpxchgWeak(worker_uninitialized, worker_initializing, .acq_rel, .acquire) == null) {
                    const queue = thread_binding.espz_queue_create(worker_queue_len, @sizeOf(*WorkerRequest)) orelse {
                        worker_queue_bits.store(worker_uninitialized, .release);
                        return error.Unexpected;
                    };
                    var handle: thread_binding.Handle = null;
                    const created = thread_binding.espz_freertos_thread_spawn_with_caps(
                        workerMain,
                        "fs_io",
                        worker_stack_size,
                        queue,
                        worker_priority,
                        &handle,
                        worker_core_id,
                        heap_binding.espz_heap_malloc_cap_internal() | heap_binding.espz_heap_malloc_cap_8bit(),
                    );
                    if (created != thread_binding.pd_true) {
                        thread_binding.espz_queue_delete(queue);
                        worker_queue_bits.store(worker_uninitialized, .release);
                        return error.Unexpected;
                    }
                    worker_handle = handle;
                    worker_queue_bits.store(@intFromPtr(queue), .release);
                    return queue;
                }
            },
            worker_initializing => thread_binding.espz_freertos_thread_yield(),
            else => return @ptrFromInt(bits),
        }
    }
}

fn workerMain(ctx: ?*anyopaque) callconv(.c) void {
    const queue: thread_binding.Handle = @ptrCast(ctx);
    while (true) {
        var request: *WorkerRequest = undefined;
        if (thread_binding.espz_queue_receive(queue, @ptrCast(&request), thread_binding.max_delay) != thread_binding.pd_true) {
            continue;
        }
        executeWorkerRequest(request);
        _ = thread_binding.espz_semaphore_give(request.done);
    }
}

fn executeWorkerRequest(request: *WorkerRequest) void {
    switch (request.op) {
        .open => request.handle = workerDoOpen(request.path, request.mode),
        .read => request.bytes = if (request.handle) |handle| workerDoRead(handle, request.buf) else 0,
        .write => request.bytes = if (request.handle) |handle| workerDoWrite(handle, request.data) else 0,
        .seek => if (request.handle) |handle| {
            request.rc = fseek(handle, request.offset, request.whence);
            request.pos = if (request.rc == 0) ftell(handle) else -1;
        } else {
            request.rc = -1;
            request.pos = -1;
        },
        .sync => request.rc = if (request.handle) |handle| fflush(handle) else -1,
        .close => request.rc = if (request.handle) |handle| fclose(handle) else -1,
        .delete_file => request.rc = workerDoPathOp(request.path, remove),
        .make_dir => request.rc = workerDoMkdir(request.path),
    }
}

fn workerDoOpen(path: []const u8, mode: FileMode) ?*CFile {
    var path_buf: [256:0]u8 = undefined;
    const c_path = pathZ(path, &path_buf) catch return null;
    return fopen(c_path, mode.text());
}

fn workerDoPathOp(path: []const u8, comptime op: fn ([*:0]const u8) callconv(.c) c_int) c_int {
    var path_buf: [256:0]u8 = undefined;
    const c_path = pathZ(path, &path_buf) catch return -1;
    return op(c_path);
}

fn workerDoMkdir(path: []const u8) c_int {
    var path_buf: [256:0]u8 = undefined;
    const c_path = pathZ(path, &path_buf) catch return -1;
    return mkdir(c_path, 0o755);
}

fn workerDoRead(handle: *CFile, buf: []u8) usize {
    var total: usize = 0;
    var chunks_since_delay: usize = 0;
    var scratch: [4096]u8 = undefined;
    while (total < buf.len) {
        const chunk_len = @min(scratch.len, buf.len - total);
        const n = fread(&scratch, 1, chunk_len, handle);
        if (n == 0) break;
        @memcpy(buf[total..][0..n], scratch[0..n]);
        total += n;
        chunks_since_delay += 1;
        if (chunks_since_delay >= 16) {
            chunks_since_delay = 0;
            thread_binding.espz_freertos_task_delay(1);
        }
        if (n < chunk_len) break;
    }
    return total;
}

fn workerDoWrite(handle: *CFile, data: []const u8) usize {
    var total: usize = 0;
    var scratch: [1024]u8 = undefined;
    while (total < data.len) {
        const chunk_len = @min(scratch.len, data.len - total);
        @memcpy(scratch[0..chunk_len], data[total..][0..chunk_len]);
        const n = fwrite(&scratch, 1, chunk_len, handle);
        total += n;
        if (n < chunk_len) break;
    }
    return total;
}

const EspFile = struct {
    handle: ?*CFile,

    pub fn read(self: *@This(), buf: []u8) fs.File.ReadError!usize {
        const handle = self.handle orelse return error.Unexpected;
        if (buf.len == 0) return 0;
        return workerRead(handle, buf) catch error.Unexpected;
    }

    pub fn write(self: *@This(), data: []const u8) fs.File.WriteError!usize {
        const handle = self.handle orelse return error.Unexpected;
        if (data.len == 0) return 0;
        return workerWrite(handle, data) catch error.Unexpected;
    }

    pub fn seek(self: *@This(), offset: i64, whence: fs.SeekWhence) fs.File.SeekError!u64 {
        const handle = self.handle orelse return error.Unexpected;
        const c_offset = castOffset(offset) orelse return error.Unexpected;
        const c_whence: c_int = switch (whence) {
            .start => seek_set,
            .current => seek_cur,
            .end => seek_end,
        };
        const pos = workerSeek(handle, c_offset, c_whence) catch return error.Unexpected;
        if (pos < 0) return error.Unexpected;
        return @intCast(pos);
    }

    pub fn sync(self: *@This()) fs.File.SyncError!void {
        const handle = self.handle orelse return error.Unexpected;
        workerSync(handle) catch return error.Unexpected;
    }

    pub fn close(self: *@This()) void {
        if (self.handle) |handle| {
            workerClose(handle);
            self.handle = null;
        }
    }

    pub fn deinit(self: *@This()) void {
        allocator.destroy(self);
    }
};

fn castOffset(offset: i64) ?c_long {
    if (offset < std.math.minInt(c_long) or offset > std.math.maxInt(c_long)) return null;
    return @intCast(offset);
}
