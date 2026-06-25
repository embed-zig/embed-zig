const std = @import("std");
const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");

pub const Preferences = embed.system.Preferences;

const Fs = gstd.runtime.fs;
const Mutex = gstd.runtime.sync.Mutex;
const default_root_path = "/storage/preferences";
const magic = "DPREF1\n";
const max_name_len = 15;
const max_file_bytes = 256 * 1024;
const max_value_bytes = 64 * 1024;
const WriteNamespaceError = error{
    PermissionDenied,
    OutOfMemory,
    NoSpaceLeft,
    Unexpected,
};

pub const Provider = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    root_path: []const u8 = default_root_path,
    mu: Mutex = .{},
    namespace_count: u8 = 0,
    namespaces: [64]Preferences.Namespace = [_]Preferences.Namespace{.{}} ** 64,

    pub const Config = struct {
        allocator: ?std.mem.Allocator = null,
        root_path: []const u8 = default_root_path,
    };

    pub fn init(config: Config) Provider {
        return .{
            .allocator = config.allocator orelse std.heap.page_allocator,
            .root_path = config.root_path,
        };
    }

    pub fn handle(self: *Provider) Preferences.Provider {
        return Preferences.Provider.init(self);
    }

    pub fn open(self: *Provider, namespace: []const u8, options: Preferences.OpenOptions) Preferences.OpenError!Preferences.Store {
        if (!isValidName(namespace)) return error.InvalidNamespace;

        self.mu.lock();
        defer self.mu.unlock();

        const path = self.namespacePath(namespace) catch return error.OutOfMemory;
        defer self.allocator.free(path);

        const exists = namespaceFileExists(path) catch |err| switch (err) {
            error.PermissionDenied => return error.PermissionDenied,
            else => return error.Unexpected,
        };
        if (!exists) {
            if (!options.create or options.read_only) return error.NotFound;
            self.writeNamespaceBytes(path, magic) catch |err| switch (err) {
                error.PermissionDenied => return error.PermissionDenied,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Unexpected,
            };
        }
        self.rememberNamespace(namespace);

        const store = self.allocator.create(Store) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(store);
        store.* = .{
            .allocator = self.allocator,
            .provider = self,
            .namespace_len = @intCast(namespace.len),
            .read_only = options.read_only,
        };
        @memcpy(store.namespace_buf[0..namespace.len], namespace);
        return Preferences.Store.init(store);
    }

    pub fn list(self: *Provider, allocator: std.mem.Allocator) Preferences.ListError![]Preferences.Namespace {
        self.mu.lock();
        defer self.mu.unlock();

        const namespaces = allocator.alloc(Preferences.Namespace, self.namespace_count) catch return error.OutOfMemory;
        errdefer allocator.free(namespaces);
        @memcpy(namespaces, self.namespaces[0..self.namespace_count]);
        return namespaces;
    }

    fn namespacePath(self: *Provider, namespace: []const u8) std.mem.Allocator.Error![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}.prefs", .{ self.root_path, namespace });
    }

    fn writeNamespaceBytes(self: *Provider, path: []const u8, bytes: []const u8) WriteNamespaceError!void {
        _ = self;
        Fs.ensureParentDirs("", path) catch |err| switch (err) {
            error.AccessDenied => return error.PermissionDenied,
            else => return error.Unexpected,
        };
        Fs.writeFile(path, bytes) catch |err| switch (err) {
            error.AccessDenied => return error.PermissionDenied,
            error.OutOfMemory => return error.OutOfMemory,
            error.NoSpaceLeft => return error.NoSpaceLeft,
            else => return error.Unexpected,
        };
    }

    fn rememberNamespace(self: *Provider, namespace: []const u8) void {
        for (self.namespaces[0..self.namespace_count]) |entry| {
            if (std.mem.eql(u8, entry.name(), namespace)) return;
        }
        if (self.namespace_count >= self.namespaces.len) return;

        var entry: Preferences.Namespace = .{
            .name_len = @intCast(namespace.len),
        };
        @memcpy(entry.name_buf[0..namespace.len], namespace);
        self.namespaces[self.namespace_count] = entry;
        self.namespace_count += 1;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    provider: *Provider,
    namespace_buf: [max_name_len]u8 = [_]u8{0} ** max_name_len,
    namespace_len: u8 = 0,
    read_only: bool = false,

    pub fn get(self: *Store, key: []const u8, out: []u8) Preferences.GetError!usize {
        if (!isValidName(key)) return error.InvalidKey;
        self.provider.mu.lock();
        defer self.provider.mu.unlock();
        return self.getLocked(key, out) catch |err| mapGetError(err);
    }

    pub fn put(self: *Store, key: []const u8, value: []const u8) Preferences.PutError!void {
        if (self.read_only) return error.PermissionDenied;
        if (!isValidName(key)) return error.InvalidKey;
        if (value.len > max_value_bytes) return error.ValueTooLarge;
        self.provider.mu.lock();
        defer self.provider.mu.unlock();
        return self.putLocked(key, value) catch |err| mapPutError(err);
    }

    pub fn remove(self: *Store, key: []const u8) Preferences.RemoveError!void {
        if (self.read_only) return error.PermissionDenied;
        if (!isValidName(key)) return error.InvalidKey;
        self.provider.mu.lock();
        defer self.provider.mu.unlock();
        return self.removeLocked(key) catch |err| mapRemoveError(err);
    }

    pub fn contains(self: *Store, key: []const u8) bool {
        if (!isValidName(key)) return false;
        self.provider.mu.lock();
        defer self.provider.mu.unlock();
        var scratch: [1]u8 = undefined;
        _ = self.getLocked(key, &scratch) catch |err| switch (err) {
            error.BufferTooSmall => return true,
            else => return false,
        };
        return true;
    }

    pub fn list(self: *Store, allocator: std.mem.Allocator) Preferences.ListError![]Preferences.Entry {
        self.provider.mu.lock();
        defer self.provider.mu.unlock();
        return self.listLocked(allocator) catch |err| mapListError(err);
    }

    pub fn clear(self: *Store) Preferences.ClearError!void {
        if (self.read_only) return error.PermissionDenied;
        self.provider.mu.lock();
        defer self.provider.mu.unlock();
        return self.writeNamespace(magic) catch |err| mapClearError(err);
    }

    pub fn sync(self: *Store) Preferences.SyncError!void {
        _ = self;
    }

    pub fn deinit(self: *Store) void {
        self.allocator.destroy(self);
    }

    fn namespace(self: *const Store) []const u8 {
        return self.namespace_buf[0..self.namespace_len];
    }

    fn getLocked(self: *Store, key: []const u8, out: []u8) !usize {
        const data = try self.readNamespace();
        defer self.allocator.free(data);

        var it = try RecordIterator.init(data);
        while (try it.next()) |record| {
            if (!std.mem.eql(u8, record.key, key)) continue;
            if (out.len < record.value.len) return error.BufferTooSmall;
            @memcpy(out[0..record.value.len], record.value);
            return record.value.len;
        }
        return error.NotFound;
    }

    fn putLocked(self: *Store, key: []const u8, value: []const u8) !void {
        const data = try self.readNamespace();
        defer self.allocator.free(data);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, magic);

        var replaced = false;
        var it = try RecordIterator.init(data);
        while (try it.next()) |record| {
            if (std.mem.eql(u8, record.key, key)) {
                try appendRecord(self.allocator, &out, key, value);
                replaced = true;
            } else {
                try appendRecord(self.allocator, &out, record.key, record.value);
            }
        }
        if (!replaced) try appendRecord(self.allocator, &out, key, value);
        try self.writeNamespace(out.items);
    }

    fn removeLocked(self: *Store, key: []const u8) !void {
        const data = try self.readNamespace();
        defer self.allocator.free(data);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, magic);

        var removed = false;
        var it = try RecordIterator.init(data);
        while (try it.next()) |record| {
            if (std.mem.eql(u8, record.key, key)) {
                removed = true;
                continue;
            }
            try appendRecord(self.allocator, &out, record.key, record.value);
        }
        if (!removed) return error.NotFound;
        try self.writeNamespace(out.items);
    }

    fn listLocked(self: *Store, allocator: std.mem.Allocator) ![]Preferences.Entry {
        const data = try self.readNamespace();
        defer self.allocator.free(data);

        var count: usize = 0;
        var count_it = try RecordIterator.init(data);
        while (try count_it.next()) |_| count += 1;

        const entries = try allocator.alloc(Preferences.Entry, count);
        errdefer allocator.free(entries);

        var index: usize = 0;
        var it = try RecordIterator.init(data);
        while (try it.next()) |record| : (index += 1) {
            var entry: Preferences.Entry = .{
                .namespace_len = @intCast(self.namespace_len),
                .key_len = @intCast(record.key.len),
                .value_type = .blob,
                .value_len = record.value.len,
            };
            @memcpy(entry.namespace_buf[0..self.namespace_len], self.namespace());
            @memcpy(entry.key_buf[0..record.key.len], record.key);
            entries[index] = entry;
        }
        return entries;
    }

    fn readNamespace(self: *Store) ![]u8 {
        const path = try self.provider.namespacePath(self.namespace());
        defer self.allocator.free(path);
        return Fs.readFileAlloc(self.allocator, path, max_file_bytes) catch |err| switch (err) {
            error.NotFound => try self.allocator.dupe(u8, magic),
            else => return err,
        };
    }

    fn writeNamespace(self: *Store, bytes: []const u8) !void {
        const path = try self.provider.namespacePath(self.namespace());
        defer self.allocator.free(path);
        try self.provider.writeNamespaceBytes(path, bytes);
    }
};

const Record = struct {
    key: []const u8,
    value: []const u8,
};

const RecordIterator = struct {
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) !RecordIterator {
        if (!std.mem.startsWith(u8, data, magic)) return error.Unexpected;
        return .{
            .data = data,
            .pos = magic.len,
        };
    }

    fn next(self: *RecordIterator) !?Record {
        if (self.pos == self.data.len) return null;
        if (self.pos + 5 > self.data.len) return error.Unexpected;
        const key_len = self.data[self.pos];
        const value_len_u32 = std.mem.readInt(u32, self.data[self.pos + 1 ..][0..4], .little);
        const value_len: usize = value_len_u32;
        self.pos += 5;

        if (key_len == 0 or key_len > max_name_len) return error.Unexpected;
        if (value_len > max_value_bytes) return error.Unexpected;
        if (self.pos + key_len + value_len > self.data.len) return error.Unexpected;

        const key = self.data[self.pos..][0..key_len];
        self.pos += key_len;
        const value = self.data[self.pos..][0..value_len];
        self.pos += value_len;
        return .{ .key = key, .value = value };
    }
};

fn appendRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    if (!isValidName(key)) return error.InvalidKey;
    if (value.len > max_value_bytes) return error.ValueTooLarge;

    var header: [5]u8 = undefined;
    header[0] = @intCast(key.len);
    std.mem.writeInt(u32, header[1..][0..4], @intCast(value.len), .little);
    try out.appendSlice(allocator, &header);
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, value);
}

fn namespaceFileExists(path: []const u8) !bool {
    _ = Fs.stat(path) catch |err| switch (err) {
        error.NotFound => return false,
        error.AccessDenied => return error.PermissionDenied,
        else => return error.Unexpected,
    };
    return true;
}

fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |ch| {
        if ((ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '_' or ch == '-')
        {
            continue;
        }
        return false;
    }
    return true;
}

fn mapGetError(err: anyerror) Preferences.GetError {
    return switch (err) {
        error.InvalidKey => error.InvalidKey,
        error.NotFound => error.NotFound,
        error.BufferTooSmall => error.BufferTooSmall,
        error.AccessDenied => error.PermissionDenied,
        else => error.Unexpected,
    };
}

fn mapPutError(err: anyerror) Preferences.PutError {
    return switch (err) {
        error.InvalidKey => error.InvalidKey,
        error.ValueTooLarge => error.ValueTooLarge,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.AccessDenied => error.PermissionDenied,
        else => error.Unexpected,
    };
}

fn mapRemoveError(err: anyerror) Preferences.RemoveError {
    return switch (err) {
        error.InvalidKey => error.InvalidKey,
        error.NotFound => error.NotFound,
        error.AccessDenied => error.PermissionDenied,
        else => error.Unexpected,
    };
}

fn mapClearError(err: anyerror) Preferences.ClearError {
    return switch (err) {
        error.AccessDenied => error.PermissionDenied,
        else => error.Unexpected,
    };
}

fn mapListError(err: anyerror) Preferences.ListError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied => error.PermissionDenied,
        else => error.Unexpected,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn persistsNamespaceEntries(allocator: std.mem.Allocator) !void {
            const root = try uniqueRoot(allocator, "desktop-preferences-persist");
            defer allocator.free(root);
            std.fs.cwd().deleteTree(root) catch {};
            defer std.fs.cwd().deleteTree(root) catch {};

            var provider = Provider.init(.{ .allocator = allocator, .root_path = root });
            var store = try provider.open("h106_id", .{ .create = true });
            try store.put("pk", "public");
            try store.put("sk", "private");
            store.deinit();

            var reopened_provider = Provider.init(.{ .allocator = allocator, .root_path = root });
            var reopened = try reopened_provider.open("h106_id", .{ .create = false });
            defer reopened.deinit();

            var buf: [16]u8 = undefined;
            const pk_len = try reopened.get("pk", &buf);
            try grt.std.testing.expectEqualStrings("public", buf[0..pk_len]);
            const sk_len = try reopened.get("sk", &buf);
            try grt.std.testing.expectEqualStrings("private", buf[0..sk_len]);
        }

        fn reportsPortableErrorsAndListsEntries(allocator: std.mem.Allocator) !void {
            const root = try uniqueRoot(allocator, "desktop-preferences-list");
            defer allocator.free(root);
            std.fs.cwd().deleteTree(root) catch {};
            defer std.fs.cwd().deleteTree(root) catch {};

            var provider = Provider.init(.{ .allocator = allocator, .root_path = root });
            try grt.std.testing.expectError(error.NotFound, provider.open("missing", .{ .create = false }));
            try grt.std.testing.expectError(error.InvalidNamespace, provider.open("../bad", .{ .create = true }));

            var store = try provider.open("wifi", .{ .create = true });
            defer store.deinit();
            try grt.std.testing.expectError(error.InvalidKey, store.put("bad/key", "x"));
            try grt.std.testing.expectError(error.NotFound, store.get("ssid", &[_]u8{}));
            try store.put("ssid", "Lab");
            try grt.std.testing.expect(store.contains("ssid"));
            try grt.std.testing.expectError(error.BufferTooSmall, store.get("ssid", &[_]u8{}));

            const entries = try store.list(allocator);
            defer allocator.free(entries);
            try grt.std.testing.expectEqual(@as(usize, 1), entries.len);
            try grt.std.testing.expectEqualStrings("wifi", entries[0].namespace());
            try grt.std.testing.expectEqualStrings("ssid", entries[0].key());
            try grt.std.testing.expectEqual(@as(usize, 3), entries[0].value_len);

            const namespaces = try provider.list(allocator);
            defer allocator.free(namespaces);
            try grt.std.testing.expectEqual(@as(usize, 1), namespaces.len);
            try grt.std.testing.expectEqualStrings("wifi", namespaces[0].name());

            try store.remove("ssid");
            try grt.std.testing.expect(!store.contains("ssid"));
            try grt.std.testing.expectError(error.NotFound, store.remove("ssid"));
        }

        fn readOnlyStoreRejectsMutation(allocator: std.mem.Allocator) !void {
            const root = try uniqueRoot(allocator, "desktop-preferences-readonly");
            defer allocator.free(root);
            std.fs.cwd().deleteTree(root) catch {};
            defer std.fs.cwd().deleteTree(root) catch {};

            var provider = Provider.init(.{ .allocator = allocator, .root_path = root });
            var writable = try provider.open("app", .{ .create = true });
            try writable.put("mode", "main");
            writable.deinit();

            var readonly = try provider.open("app", .{ .create = false, .read_only = true });
            defer readonly.deinit();
            try grt.std.testing.expectError(error.PermissionDenied, readonly.put("mode", "mfg"));
            try grt.std.testing.expectError(error.PermissionDenied, readonly.remove("mode"));
            try grt.std.testing.expectError(error.PermissionDenied, readonly.clear());
        }

        fn uniqueRoot(allocator: std.mem.Allocator, comptime prefix: []const u8) ![]u8 {
            return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}-{d}", .{ prefix, std.time.nanoTimestamp() });
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: std.mem.Allocator) bool {
            _ = self;

            TestCase.persistsNamespaceEntries(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.reportsPortableErrorsAndListsEntries(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.readOnlyStoreRejectsMutation(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
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
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
