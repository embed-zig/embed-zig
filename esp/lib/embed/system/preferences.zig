const embed = @import("embed_core");
const esp = @import("esp");
const glib = esp.glib;
const binding = @import("preferences_binding.zig");
const NativeTask = esp.native_task;

const Preferences = embed.system.Preferences;
const allocator_default = esp.heap.Allocator(.{ .caps = .internal_8bit, .alignment = .align_u32 });
const max_name_len = 15;
const request_stack_size = 3 * 1024;
const max_usize = glib.std.math.maxInt(usize);

var request_count = glib.std.atomic.Value(usize).init(0);
var min_stack_free_bytes = glib.std.atomic.Value(usize).init(max_usize);

pub const Stats = struct {
    request_count: usize,
    request_stack_size: usize,
    min_stack_free_bytes: usize,
};

pub fn resetStats() void {
    request_count.store(0, .release);
    min_stack_free_bytes.store(max_usize, .release);
}

pub fn stats() Stats {
    const min_stack = min_stack_free_bytes.load(.acquire);
    return .{
        .request_count = request_count.load(.acquire),
        .request_stack_size = request_stack_size,
        .min_stack_free_bytes = if (min_stack == max_usize) 0 else min_stack,
    };
}

pub const Provider = struct {
    allocator: esp.grt.std.mem.Allocator = allocator_default,

    pub fn init(config: Config) Provider {
        return .{
            .allocator = config.allocator orelse allocator_default,
        };
    }

    pub fn handle(self: *Provider) Preferences.Provider {
        return Preferences.Provider.init(self);
    }

    pub fn open(self: *Provider, namespace: []const u8, options: Preferences.OpenOptions) Preferences.OpenError!Preferences.Store {
        try checkInit(runPreferenceRequest(.{ .op = .init }).rc);

        if (!options.create and !options.read_only) {
            const probe = runPreferenceRequest(.{
                .op = .open,
                .namespace = namespace,
                .read_only = true,
            });
            const probe_rc = probe.rc;
            try checkOpen(probe_rc);
            _ = runPreferenceRequest(.{
                .op = .close,
                .handle = probe.handle,
            });
        }

        const opened = runPreferenceRequest(.{
            .op = .open,
            .namespace = namespace,
            .read_only = options.read_only,
        });
        const rc = opened.rc;
        try checkOpen(rc);

        const store = self.allocator.create(Store) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(store);
        store.* = .{
            .allocator = self.allocator,
            .handle = opened.handle,
        };
        return Preferences.Store.init(store);
    }

    pub fn list(self: *Provider, allocator: esp.grt.std.mem.Allocator) Preferences.ListError![]Preferences.Namespace {
        _ = self;
        try checkListInit(runPreferenceRequest(.{ .op = .init }).rc);
        return namespaceListAlloc(allocator, .{ .op = .list_namespaces });
    }

    pub const Config = struct {
        allocator: ?esp.grt.std.mem.Allocator = null,
    };
};

pub const Store = struct {
    allocator: esp.grt.std.mem.Allocator,
    handle: binding.Handle,

    pub fn get(self: *Store, key: []const u8, out: []u8) Preferences.GetError!usize {
        const result = runPreferenceRequest(.{
            .op = .get,
            .handle = self.handle,
            .key = key,
            .out = out,
        });
        try checkGet(result.rc);
        return result.len;
    }

    pub fn getAlloc(self: *Store, allocator: esp.grt.std.mem.Allocator, key: []const u8) Preferences.GetAllocError![]u8 {
        const len_result = runPreferenceRequest(.{
            .op = .get,
            .handle = self.handle,
            .key = key,
            .out = &.{},
        });
        try checkGet(len_result.rc);

        const value = allocator.alloc(u8, len_result.len) catch return error.OutOfMemory;
        errdefer allocator.free(value);
        if (value.len == 0) return value;

        const read_result = runPreferenceRequest(.{
            .op = .get,
            .handle = self.handle,
            .key = key,
            .out = value,
        });
        try checkGet(read_result.rc);
        if (read_result.len != value.len) return error.Unexpected;
        return value;
    }

    pub fn put(self: *Store, key: []const u8, value: []const u8) Preferences.PutError!void {
        const rc = runPreferenceRequest(.{
            .op = .put,
            .handle = self.handle,
            .key = key,
            .value = value,
        }).rc;
        return checkPut(rc);
    }

    pub fn remove(self: *Store, key: []const u8) Preferences.RemoveError!void {
        const rc = runPreferenceRequest(.{
            .op = .remove,
            .handle = self.handle,
            .key = key,
        }).rc;
        return checkRemove(rc);
    }

    pub fn contains(self: *Store, key: []const u8) bool {
        return runPreferenceRequest(.{
            .op = .contains,
            .handle = self.handle,
            .key = key,
        }).found;
    }

    pub fn list(self: *Store, allocator: esp.grt.std.mem.Allocator) Preferences.ListError![]Preferences.Entry {
        return listAlloc(allocator, .{
            .op = .list,
            .handle = self.handle,
        });
    }

    pub fn clear(self: *Store) Preferences.ClearError!void {
        return checkClear(runPreferenceRequest(.{
            .op = .clear,
            .handle = self.handle,
        }).rc);
    }

    pub fn sync(self: *Store) Preferences.SyncError!void {
        return checkSync(runPreferenceRequest(.{
            .op = .sync,
            .handle = self.handle,
        }).rc);
    }

    pub fn deinit(self: *Store) void {
        _ = runPreferenceRequest(.{
            .op = .close,
            .handle = self.handle,
        });
        self.allocator.destroy(self);
    }
};

const Operation = enum {
    init,
    open,
    close,
    get,
    put,
    remove,
    contains,
    list,
    list_namespaces,
    clear,
    sync,
};

const RequestSpec = struct {
    op: Operation,
    namespace: []const u8 = &.{},
    read_only: bool = false,
    handle: binding.Handle = null,
    key: []const u8 = &.{},
    value: []const u8 = &.{},
    out: []u8 = &.{},
    entries: []Preferences.Entry = &.{},
    namespaces: []Preferences.Namespace = &.{},
};

const RequestResult = struct {
    rc: i32 = 0,
    handle: binding.Handle = null,
    len: usize = 0,
    found: bool = false,
};

const Request = struct {
    spec: RequestSpec,
    result: RequestResult = .{},
};

fn runPreferenceRequest(spec: RequestSpec) RequestResult {
    var request = Request{ .spec = spec };
    const handle = NativeTask.spawn(.{
        .name = "esp_prefs",
        .stack_size = request_stack_size,
        .priority = 7,
        .stack_memory = .internal,
    }, glib.task.Routine.init(&request, runPreferenceRequestTask)) catch |err| {
        return .{ .rc = spawnErrorCode(err) };
    };
    handle.join();
    return request.result;
}

fn runPreferenceRequestTask(request: *Request) void {
    request.result = process(request.spec);
    recordRequestStack();
}

fn process(spec: RequestSpec) RequestResult {
    return switch (spec.op) {
        .init => .{ .rc = binding.esp_embed_preferences_init() },
        .open => openOnWorker(spec.namespace, spec.read_only),
        .close => closeOnWorker(spec.handle),
        .get => getOnWorker(spec.handle, spec.key, spec.out),
        .put => putOnWorker(spec.handle, spec.key, spec.value),
        .remove => removeOnWorker(spec.handle, spec.key),
        .contains => containsOnWorker(spec.handle, spec.key),
        .list => listOnWorker(spec.handle, spec.entries),
        .list_namespaces => listNamespacesOnWorker(spec.namespaces),
        .clear => .{ .rc = binding.esp_embed_preferences_clear(spec.handle) },
        .sync => .{ .rc = binding.esp_embed_preferences_sync(spec.handle) },
    };
}

fn recordRequestStack() void {
    _ = request_count.fetchAdd(1, .acq_rel);

    const stack_free = NativeTask.currentStackHighWaterMarkBytes();
    while (true) {
        const current = min_stack_free_bytes.load(.acquire);
        if (stack_free >= current) return;
        if (min_stack_free_bytes.cmpxchgWeak(current, stack_free, .acq_rel, .acquire) == null) return;
    }
}

fn listAlloc(allocator: esp.grt.std.mem.Allocator, spec: RequestSpec) Preferences.ListError![]Preferences.Entry {
    const count_result = runPreferenceRequest(spec);
    try checkList(count_result.rc);

    const entries = allocator.alloc(Preferences.Entry, count_result.len) catch return error.OutOfMemory;
    errdefer allocator.free(entries);
    if (entries.len == 0) return entries;

    var fill_spec = spec;
    fill_spec.entries = entries;
    const fill_result = runPreferenceRequest(fill_spec);
    try checkList(fill_result.rc);
    if (fill_result.len > entries.len) return error.OutOfMemory;
    return entries;
}

fn namespaceListAlloc(allocator: esp.grt.std.mem.Allocator, spec: RequestSpec) Preferences.ListError![]Preferences.Namespace {
    const count_result = runPreferenceRequest(spec);
    try checkList(count_result.rc);

    const namespaces = allocator.alloc(Preferences.Namespace, count_result.len) catch return error.OutOfMemory;
    errdefer allocator.free(namespaces);
    if (namespaces.len == 0) return namespaces;

    var fill_spec = spec;
    fill_spec.namespaces = namespaces;
    const fill_result = runPreferenceRequest(fill_spec);
    try checkList(fill_result.rc);
    if (fill_result.len > namespaces.len) return error.OutOfMemory;
    return namespaces;
}

fn openOnWorker(namespace: []const u8, read_only: bool) RequestResult {
    var namespace_buf: [max_name_len]u8 = undefined;
    const safe_namespace = copyNvsName(&namespace_buf, namespace) orelse
        return .{ .rc = binding.esp_embed_preferences_err_nvs_invalid_name };

    var handle: binding.Handle = null;
    const rc = binding.esp_embed_preferences_open(
        safe_namespace.ptr,
        safe_namespace.len,
        read_only,
        &handle,
    );
    return .{ .rc = rc, .handle = handle };
}

fn closeOnWorker(handle: binding.Handle) RequestResult {
    binding.esp_embed_preferences_close(handle);
    return .{};
}

fn getOnWorker(handle: binding.Handle, key: []const u8, out: []u8) RequestResult {
    var key_buf: [max_name_len]u8 = undefined;
    const safe_key = copyNvsName(&key_buf, key) orelse
        return .{ .rc = binding.esp_embed_preferences_err_nvs_invalid_name };

    if (out.len == 0) {
        var len: usize = 0;
        const rc = binding.esp_embed_preferences_get(
            handle,
            safe_key.ptr,
            safe_key.len,
            null,
            &len,
        );
        return .{ .rc = rc, .len = len };
    }

    const internal_out = allocator_default.alloc(u8, out.len) catch
        return .{ .rc = binding.esp_embed_preferences_err_no_mem };
    defer allocator_default.free(internal_out);

    var len = out.len;
    const rc = binding.esp_embed_preferences_get(
        handle,
        safe_key.ptr,
        safe_key.len,
        internal_out.ptr,
        &len,
    );
    if (rc == binding.esp_embed_preferences_ok) {
        @memcpy(out[0..@min(out.len, len)], internal_out[0..@min(internal_out.len, len)]);
    }
    return .{ .rc = rc, .len = len };
}

fn putOnWorker(handle: binding.Handle, key: []const u8, value: []const u8) RequestResult {
    var key_buf: [max_name_len]u8 = undefined;
    const safe_key = copyNvsName(&key_buf, key) orelse
        return .{ .rc = binding.esp_embed_preferences_err_nvs_invalid_name };

    const internal_value = allocator_default.alloc(u8, value.len) catch
        return .{ .rc = binding.esp_embed_preferences_err_no_mem };
    defer allocator_default.free(internal_value);
    @memcpy(internal_value, value);

    return .{ .rc = binding.esp_embed_preferences_put(
        handle,
        safe_key.ptr,
        safe_key.len,
        internal_value.ptr,
        internal_value.len,
    ) };
}

fn removeOnWorker(handle: binding.Handle, key: []const u8) RequestResult {
    var key_buf: [max_name_len]u8 = undefined;
    const safe_key = copyNvsName(&key_buf, key) orelse
        return .{ .rc = binding.esp_embed_preferences_err_nvs_invalid_name };

    return .{ .rc = binding.esp_embed_preferences_remove(
        handle,
        safe_key.ptr,
        safe_key.len,
    ) };
}

fn containsOnWorker(handle: binding.Handle, key: []const u8) RequestResult {
    var key_buf: [max_name_len]u8 = undefined;
    const safe_key = copyNvsName(&key_buf, key) orelse
        return .{ .found = false };

    return .{ .found = binding.esp_embed_preferences_contains(
        handle,
        safe_key.ptr,
        safe_key.len,
    ) };
}

fn listOnWorker(handle: binding.Handle, out: []Preferences.Entry) RequestResult {
    const temp_capacity = @max(out.len, 1);
    const temp = allocator_default.alloc(binding.Entry, temp_capacity) catch
        return .{ .rc = binding.esp_embed_preferences_err_no_mem };
    defer allocator_default.free(temp);

    var count: usize = 0;
    const rc = binding.esp_embed_preferences_list(
        handle,
        temp.ptr,
        out.len,
        &count,
    );
    if (rc == binding.esp_embed_preferences_ok) {
        const copy_count = @min(out.len, count);
        for (temp[0..copy_count], 0..) |entry, index| {
            out[index] = convertEntry(entry);
        }
    }
    return .{ .rc = rc, .len = count };
}

fn listNamespacesOnWorker(out: []Preferences.Namespace) RequestResult {
    const temp_capacity = @max(out.len, 1);
    const temp = allocator_default.alloc(binding.Namespace, temp_capacity) catch
        return .{ .rc = binding.esp_embed_preferences_err_no_mem };
    defer allocator_default.free(temp);

    var count: usize = 0;
    const rc = binding.esp_embed_preferences_list_namespaces(
        temp.ptr,
        out.len,
        &count,
    );
    if (rc == binding.esp_embed_preferences_ok) {
        const copy_count = @min(out.len, count);
        for (temp[0..copy_count], 0..) |namespace, index| {
            out[index] = convertNamespace(namespace);
        }
    }
    return .{ .rc = rc, .len = count };
}

fn convertNamespace(namespace: binding.Namespace) Preferences.Namespace {
    var result: Preferences.Namespace = .{};
    result.name_len = copyCString(&result.name_buf, &namespace.name);
    return result;
}

fn convertEntry(entry: binding.Entry) Preferences.Entry {
    var result: Preferences.Entry = .{
        .value_type = entryType(entry.value_type),
        .value_len = entry.value_len,
    };
    result.namespace_len = copyCString(&result.namespace_buf, &entry.namespace_name);
    result.key_len = copyCString(&result.key_buf, &entry.key);
    return result;
}

fn copyCString(out: *[16]u8, in: *const [16]u8) u8 {
    const len = glib.std.mem.indexOfScalar(u8, in, 0) orelse in.len;
    const copy_len = @min(out.len, len);
    @memset(out, 0);
    @memcpy(out[0..copy_len], in[0..copy_len]);
    return @intCast(copy_len);
}

fn entryType(value: i32) Preferences.EntryType {
    return switch (value) {
        0x01 => .u8,
        0x11 => .i8,
        0x02 => .u16,
        0x12 => .i16,
        0x04 => .u32,
        0x14 => .i32,
        0x08 => .u64,
        0x18 => .i64,
        0x21 => .string,
        0x42 => .blob,
        else => .unknown,
    };
}

fn copyNvsName(dst: *[max_name_len]u8, src: []const u8) ?[]const u8 {
    if (src.len == 0 or src.len > max_name_len) return null;
    @memcpy(dst[0..src.len], src);
    return dst[0..src.len];
}

fn spawnErrorCode(err: NativeTask.SpawnError) i32 {
    return switch (err) {
        error.OutOfMemory => binding.esp_embed_preferences_err_no_mem,
        else => binding.esp_embed_preferences_err_invalid_state,
    };
}

fn checkInit(rc: i32) Preferences.OpenError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_no_mem) return error.OutOfMemory;
    if (rc == binding.esp_embed_preferences_err_invalid_state) return error.Unexpected;
    if (rc == binding.esp_embed_preferences_err_no_free_pages) return error.Unexpected;
    if (rc == binding.esp_embed_preferences_err_new_version_found) return error.Unexpected;
    return error.Unexpected;
}

fn checkOpen(rc: i32) Preferences.OpenError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_invalid_arg) return error.InvalidNamespace;
    if (rc == binding.esp_embed_preferences_err_nvs_invalid_name) return error.InvalidNamespace;
    if (rc == binding.esp_embed_preferences_err_not_found) return error.NotFound;
    if (rc == binding.esp_embed_preferences_err_no_mem) return error.OutOfMemory;
    if (rc == binding.esp_embed_preferences_err_nvs_read_only) return error.PermissionDenied;
    return error.Unexpected;
}

fn checkGet(rc: i32) Preferences.GetError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_invalid_arg) return error.InvalidKey;
    if (rc == binding.esp_embed_preferences_err_nvs_invalid_name) return error.InvalidKey;
    if (rc == binding.esp_embed_preferences_err_nvs_invalid_handle) return error.Unexpected;
    if (rc == binding.esp_embed_preferences_err_not_found) return error.NotFound;
    if (rc == binding.esp_embed_preferences_err_nvs_invalid_length) return error.BufferTooSmall;
    if (rc == binding.esp_embed_preferences_err_nvs_value_too_long) return error.BufferTooSmall;
    return error.Unexpected;
}

fn checkPut(rc: i32) Preferences.PutError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_invalid_arg) return error.InvalidKey;
    if (rc == binding.esp_embed_preferences_err_nvs_invalid_name) return error.InvalidKey;
    if (rc == binding.esp_embed_preferences_err_nvs_read_only) return error.PermissionDenied;
    if (rc == binding.esp_embed_preferences_err_nvs_not_enough_space) return error.NoSpaceLeft;
    if (rc == binding.esp_embed_preferences_err_nvs_value_too_long) return error.ValueTooLarge;
    return error.Unexpected;
}

fn checkRemove(rc: i32) Preferences.RemoveError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_invalid_arg) return error.InvalidKey;
    if (rc == binding.esp_embed_preferences_err_nvs_invalid_name) return error.InvalidKey;
    if (rc == binding.esp_embed_preferences_err_nvs_read_only) return error.PermissionDenied;
    if (rc == binding.esp_embed_preferences_err_not_found) return error.NotFound;
    return error.Unexpected;
}

fn checkClear(rc: i32) Preferences.ClearError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_nvs_read_only) return error.PermissionDenied;
    return error.Unexpected;
}

fn checkList(rc: i32) Preferences.ListError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_no_mem) return error.OutOfMemory;
    if (rc == binding.esp_embed_preferences_err_nvs_read_only) return error.PermissionDenied;
    return error.Unexpected;
}

fn checkListInit(rc: i32) Preferences.ListError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_no_mem) return error.OutOfMemory;
    return error.Unexpected;
}

fn checkSync(rc: i32) Preferences.SyncError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    return error.Unexpected;
}
