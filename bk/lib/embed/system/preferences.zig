const bk = @import("../../bk.zig");
const embed = @import("embed_core");
const binding = @import("preferences_binding.zig");

const Preferences = embed.system.Preferences;

const max_name_len = 15;

pub const Provider = struct {
    allocator: bk.ap.grt.std.mem.Allocator = bk.heap.allocator,

    pub fn init(config: Config) !Provider {
        const provider: Provider = .{
            .allocator = config.allocator orelse bk.heap.allocator,
        };
        try checkOpen(binding.bk_embed_preferences_init());
        return provider;
    }

    pub fn handle(self: *Provider) Preferences.Provider {
        return Preferences.Provider.init(self);
    }

    pub fn open(self: *Provider, namespace: []const u8, options: Preferences.OpenOptions) Preferences.OpenError!Preferences.Store {
        try checkOpen(binding.bk_embed_preferences_init());
        if (!options.create and !hasNamespace(namespace)) return error.NotFound;

        const store = self.allocator.create(Store) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(store);
        store.* = .{
            .allocator = self.allocator,
        };
        store.setNamespace(namespace) catch return error.InvalidNamespace;
        return Preferences.Store.init(store);
    }

    pub fn list(self: *Provider, allocator: bk.ap.grt.std.mem.Allocator) Preferences.ListError![]Preferences.Namespace {
        _ = self;
        try checkList(binding.bk_embed_preferences_init());
        return namespaceListAlloc(allocator);
    }

    pub const Config = struct {
        allocator: ?bk.ap.grt.std.mem.Allocator = null,
    };
};

pub const Store = struct {
    allocator: bk.ap.grt.std.mem.Allocator,
    namespace_buf: [16]u8 = [_]u8{0} ** 16,
    namespace_len: u8 = 0,

    pub fn get(self: *Store, key: []const u8, out: []u8) Preferences.GetError!usize {
        var len = out.len;
        const rc = binding.bk_embed_preferences_get(
            self.namespace().ptr,
            self.namespace().len,
            key.ptr,
            key.len,
            if (out.len == 0) null else out.ptr,
            &len,
        );
        try checkGet(rc);
        return len;
    }

    pub fn getAlloc(self: *Store, allocator: bk.ap.grt.std.mem.Allocator, key: []const u8) Preferences.GetAllocError![]u8 {
        var len: usize = 0;
        var rc = binding.bk_embed_preferences_get(
            self.namespace().ptr,
            self.namespace().len,
            key.ptr,
            key.len,
            null,
            &len,
        );
        try checkGet(rc);

        const value = allocator.alloc(u8, len) catch return error.OutOfMemory;
        errdefer allocator.free(value);
        if (value.len == 0) return value;

        rc = binding.bk_embed_preferences_get(
            self.namespace().ptr,
            self.namespace().len,
            key.ptr,
            key.len,
            value.ptr,
            &len,
        );
        try checkGet(rc);
        if (len != value.len) return error.Unexpected;
        return value;
    }

    pub fn put(self: *Store, key: []const u8, value: []const u8) Preferences.PutError!void {
        const rc = binding.bk_embed_preferences_put(
            self.namespace().ptr,
            self.namespace().len,
            key.ptr,
            key.len,
            value.ptr,
            value.len,
        );
        return checkPut(rc);
    }

    pub fn remove(self: *Store, key: []const u8) Preferences.RemoveError!void {
        const rc = binding.bk_embed_preferences_remove(
            self.namespace().ptr,
            self.namespace().len,
            key.ptr,
            key.len,
        );
        return checkRemove(rc);
    }

    pub fn contains(self: *Store, key: []const u8) bool {
        return binding.bk_embed_preferences_contains(
            self.namespace().ptr,
            self.namespace().len,
            key.ptr,
            key.len,
        );
    }

    pub fn list(self: *Store, allocator: bk.ap.grt.std.mem.Allocator) Preferences.ListError![]Preferences.Entry {
        return listAlloc(allocator, self.namespace());
    }

    pub fn clear(self: *Store) Preferences.ClearError!void {
        const rc = binding.bk_embed_preferences_clear(self.namespace().ptr, self.namespace().len);
        return checkClear(rc);
    }

    pub fn sync(_: *Store) Preferences.SyncError!void {
        return checkSync(binding.bk_embed_preferences_sync());
    }

    pub fn deinit(self: *Store) void {
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn setNamespace(self: *Store, namespace_value: []const u8) !void {
        if (namespace_value.len == 0 or namespace_value.len > max_name_len) return error.InvalidNamespace;
        @memset(&self.namespace_buf, 0);
        @memcpy(self.namespace_buf[0..namespace_value.len], namespace_value);
        self.namespace_len = @intCast(namespace_value.len);
    }

    fn namespace(self: *const Store) []const u8 {
        return self.namespace_buf[0..self.namespace_len];
    }
};

fn hasNamespace(namespace: []const u8) bool {
    var namespaces_buf: [8]binding.Namespace = undefined;
    var count: usize = 0;
    const rc = binding.bk_embed_preferences_list_namespaces(&namespaces_buf, namespaces_buf.len, &count);
    if (rc != binding.ok) return false;

    for (namespaces_buf[0..@min(count, namespaces_buf.len)]) |native| {
        const name = cString(&native.name);
        if (bk.ap.grt.std.mem.eql(u8, name, namespace)) return true;
    }
    return false;
}

fn listAlloc(allocator: bk.ap.grt.std.mem.Allocator, namespace: []const u8) Preferences.ListError![]Preferences.Entry {
    var count: usize = 0;
    try checkList(binding.bk_embed_preferences_list(namespace.ptr, namespace.len, null, 0, &count));

    const entries = allocator.alloc(Preferences.Entry, count) catch return error.OutOfMemory;
    errdefer allocator.free(entries);
    if (entries.len == 0) return entries;

    const native_entries = allocator.alloc(binding.Entry, entries.len) catch return error.OutOfMemory;
    defer allocator.free(native_entries);

    try checkList(binding.bk_embed_preferences_list(namespace.ptr, namespace.len, native_entries.ptr, native_entries.len, &count));
    if (count > entries.len) return error.OutOfMemory;

    for (native_entries[0..count], 0..) |native, index| {
        entries[index] = convertEntry(native);
    }
    return entries;
}

fn namespaceListAlloc(allocator: bk.ap.grt.std.mem.Allocator) Preferences.ListError![]Preferences.Namespace {
    var count: usize = 0;
    try checkList(binding.bk_embed_preferences_list_namespaces(null, 0, &count));

    const namespaces = allocator.alloc(Preferences.Namespace, count) catch return error.OutOfMemory;
    errdefer allocator.free(namespaces);
    if (namespaces.len == 0) return namespaces;

    const native_namespaces = allocator.alloc(binding.Namespace, namespaces.len) catch return error.OutOfMemory;
    defer allocator.free(native_namespaces);

    try checkList(binding.bk_embed_preferences_list_namespaces(native_namespaces.ptr, native_namespaces.len, &count));
    if (count > namespaces.len) return error.OutOfMemory;

    for (native_namespaces[0..count], 0..) |native, index| {
        namespaces[index] = convertNamespace(native);
    }
    return namespaces;
}

fn convertNamespace(namespace: binding.Namespace) Preferences.Namespace {
    var result: Preferences.Namespace = .{};
    result.name_len = copyCString(&result.name_buf, &namespace.name);
    return result;
}

fn convertEntry(entry: binding.Entry) Preferences.Entry {
    var result: Preferences.Entry = .{
        .value_type = .blob,
        .value_len = entry.value_len,
    };
    result.namespace_len = copyCString(&result.namespace_buf, &entry.namespace_name);
    result.key_len = copyCString(&result.key_buf, &entry.key);
    return result;
}

fn copyCString(out: *[16]u8, in: *const [16]u8) u8 {
    const copy_len = @min(out.len, cString(in).len);
    @memset(out, 0);
    @memcpy(out[0..copy_len], in[0..copy_len]);
    return @intCast(copy_len);
}

fn cString(in: *const [16]u8) []const u8 {
    const len = bk.ap.grt.std.mem.indexOfScalar(u8, in, 0) orelse in.len;
    return in[0..len];
}

fn checkOpen(rc: c_int) Preferences.OpenError!void {
    if (rc == binding.ok) return;
    if (rc == binding.no_mem) return error.OutOfMemory;
    if (rc == binding.invalid_name) return error.InvalidNamespace;
    return error.Unexpected;
}

fn checkGet(rc: c_int) Preferences.GetError!void {
    if (rc == binding.ok) return;
    if (rc == binding.not_found) return error.NotFound;
    if (rc == binding.no_space) return error.BufferTooSmall;
    if (rc == binding.invalid_name) return error.InvalidKey;
    return error.Unexpected;
}

fn checkPut(rc: c_int) Preferences.PutError!void {
    if (rc == binding.ok) return;
    if (rc == binding.no_mem) return error.NoSpaceLeft;
    if (rc == binding.no_space) return error.NoSpaceLeft;
    if (rc == binding.invalid_name) return error.InvalidKey;
    return error.Unexpected;
}

fn checkRemove(rc: c_int) Preferences.RemoveError!void {
    if (rc == binding.ok) return;
    if (rc == binding.not_found) return error.NotFound;
    if (rc == binding.invalid_name) return error.InvalidKey;
    return error.Unexpected;
}

fn checkClear(rc: c_int) Preferences.ClearError!void {
    if (rc == binding.ok) return;
    if (rc == binding.invalid_name) return error.PermissionDenied;
    return error.Unexpected;
}

fn checkSync(rc: c_int) Preferences.SyncError!void {
    if (rc == binding.ok) return;
    return error.Unexpected;
}

fn checkList(rc: c_int) Preferences.ListError!void {
    if (rc == binding.ok) return;
    if (rc == binding.no_mem) return error.OutOfMemory;
    return error.Unexpected;
}
