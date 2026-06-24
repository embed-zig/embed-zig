//! system — platform-provided services above chip-level drivers.

const glib = @import("glib");

pub const Preferences = @import("system/Preferences.zig");

pub const test_runner = struct {
    pub const unit = struct {
        pub fn make(comptime grt: type) glib.testing.TestRunner {
            return TestRunner(grt);
        }
    };
};

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn providerOpensNamespaceBoundStores() !void {
            var impl = TestPreferences.init();
            const provider = Preferences.Provider.init(&impl);

            var wifi = try provider.open("wifi", .{ .create = true });
            defer wifi.deinit();
            var app = try provider.open("app", .{ .create = true });
            defer app.deinit();

            try wifi.put("ssid", "Lab");
            try app.put("ssid", "Other");

            var buf: [16]u8 = undefined;
            const wifi_len = try wifi.get("ssid", &buf);
            try grt.std.testing.expectEqualStrings("Lab", buf[0..wifi_len]);
            const app_len = try app.get("ssid", &buf);
            try grt.std.testing.expectEqualStrings("Other", buf[0..app_len]);
            try grt.std.testing.expect(wifi.contains("ssid"));
            try grt.std.testing.expect(app.contains("ssid"));
        }

        fn missingAndSmallBuffersReportPortableErrors() !void {
            var impl = TestPreferences.init();
            const provider = Preferences.Provider.init(&impl);

            var store = try provider.open("wifi", .{ .create = true });
            defer store.deinit();

            var buf: [2]u8 = undefined;
            try grt.std.testing.expectError(error.NotFound, store.get("ssid", &buf));
            try store.put("ssid", "Lab");
            try grt.std.testing.expectError(error.BufferTooSmall, store.get("ssid", &buf));
            try store.remove("ssid");
            try grt.std.testing.expect(!store.contains("ssid"));
        }

        fn openCreateControlsNamespaceCreation() !void {
            var impl = TestPreferences.init();
            const provider = Preferences.Provider.init(&impl);

            try grt.std.testing.expectError(error.NotFound, provider.open("new", .{ .create = false }));

            var created = try provider.open("new", .{ .create = true });
            defer created.deinit();
            try created.put("key", "value");

            var reopened = try provider.open("new", .{ .create = false });
            defer reopened.deinit();
            var buf: [8]u8 = undefined;
            const len = try reopened.get("key", &buf);
            try grt.std.testing.expectEqualStrings("value", buf[0..len]);
        }

        fn listReportsNamespaceEntries(allocator: glib.std.mem.Allocator) !void {
            var impl = TestPreferences.init();
            const provider = Preferences.Provider.init(&impl);

            var store = try provider.open("wifi", .{ .create = true });
            defer store.deinit();

            try store.put("ssid", "Lab");
            try store.put("token", "secret");

            const entries = try store.list(allocator);
            defer allocator.free(entries);
            try grt.std.testing.expectEqual(@as(usize, 2), entries.len);
            try grt.std.testing.expectEqualStrings("wifi", entries[0].namespace());
            try grt.std.testing.expectEqualStrings("ssid", entries[0].key());
            try grt.std.testing.expectEqual(@as(usize, 3), entries[0].value_len);
            try grt.std.testing.expectEqual(Preferences.EntryType.blob, entries[0].value_type);
            try grt.std.testing.expectEqualStrings("wifi", entries[1].namespace());
            try grt.std.testing.expectEqualStrings("token", entries[1].key());
            try grt.std.testing.expectEqual(@as(usize, 6), entries[1].value_len);
            try grt.std.testing.expectEqual(Preferences.EntryType.blob, entries[1].value_type);
        }

        fn providerListReportsNamespaces(allocator: glib.std.mem.Allocator) !void {
            var impl = TestPreferences.init();
            const provider = Preferences.Provider.init(&impl);

            var wifi = try provider.open("wifi", .{ .create = true });
            defer wifi.deinit();
            var app = try provider.open("app", .{ .create = true });
            defer app.deinit();

            try wifi.put("ssid", "Lab");
            try app.put("mode", "mfg");

            const namespaces = try provider.list(allocator);
            defer allocator.free(namespaces);
            try grt.std.testing.expectEqual(@as(usize, 2), namespaces.len);
            try grt.std.testing.expectEqualStrings("wifi", namespaces[0].name());
            try grt.std.testing.expectEqualStrings("app", namespaces[1].name());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.providerOpensNamespaceBoundStores() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.missingAndSmallBuffersReportPortableErrors() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.openCreateControlsNamespaceCreation() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.listReportsNamespaceEntries(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.providerListReportsNamespaces(allocator) catch |err| {
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

const TestPreferences = struct {
    stores: [3]TestStore,

    fn init() TestPreferences {
        return .{
            .stores = .{
                TestStore.init("wifi"),
                TestStore.init("app"),
                TestStore.empty(),
            },
        };
    }

    pub fn open(self: *TestPreferences, namespace: []const u8, options: Preferences.OpenOptions) Preferences.OpenError!Preferences.Store {
        for (&self.stores) |*store| {
            if (store.active and glib.std.mem.eql(u8, store.namespace(), namespace)) return Preferences.Store.init(store);
        }
        if (!options.create or options.read_only) return error.NotFound;

        for (&self.stores) |*store| {
            if (!store.active) {
                store.setNamespace(namespace) catch return error.InvalidNamespace;
                return Preferences.Store.init(store);
            }
        }
        return error.NotFound;
    }

    pub fn list(self: *TestPreferences, allocator: glib.std.mem.Allocator) Preferences.ListError![]Preferences.Namespace {
        var count: usize = 0;
        for (&self.stores) |*store| {
            if (!store.active) continue;
            count += 1;
        }

        const namespaces = allocator.alloc(Preferences.Namespace, count) catch return error.OutOfMemory;
        errdefer allocator.free(namespaces);

        var index: usize = 0;
        for (&self.stores) |*store| {
            if (!store.active) continue;
            namespaces[index] = .{ .name_len = @intCast(store.namespace_len) };
            @memcpy(namespaces[index].name_buf[0..store.namespace_len], store.namespace());
            index += 1;
        }
        return namespaces;
    }
};

const TestStore = struct {
    active: bool = false,
    namespace_buf: [16]u8 = [_]u8{0} ** 16,
    namespace_len: usize = 0,
    entries: [4]Entry = [_]Entry{.{}} ** 4,

    const Entry = struct {
        key_buf: [16]u8 = [_]u8{0} ** 16,
        key_len: usize = 0,
        value_buf: [32]u8 = [_]u8{0} ** 32,
        value_len: usize = 0,
        present: bool = false,

        fn key(self: *const Entry) []const u8 {
            return self.key_buf[0..self.key_len];
        }

        fn value(self: *const Entry) []const u8 {
            return self.value_buf[0..self.value_len];
        }
    };

    fn empty() TestStore {
        return .{};
    }

    fn init(namespace_value: []const u8) TestStore {
        var store = TestStore{};
        store.setNamespace(namespace_value) catch unreachable;
        return store;
    }

    fn setNamespace(self: *TestStore, namespace_value: []const u8) !void {
        if (namespace_value.len == 0 or namespace_value.len > self.namespace_buf.len) return error.InvalidNamespace;
        @memset(&self.namespace_buf, 0);
        self.namespace_len = namespace_value.len;
        @memcpy(self.namespace_buf[0..namespace_value.len], namespace_value);
        self.active = true;
    }

    fn namespace(self: *const TestStore) []const u8 {
        return self.namespace_buf[0..self.namespace_len];
    }

    pub fn get(self: *TestStore, key: []const u8, out: []u8) Preferences.GetError!usize {
        const entry = self.find(key) orelse return error.NotFound;
        const value = entry.value();
        if (out.len < value.len) return error.BufferTooSmall;
        @memcpy(out[0..value.len], value);
        return value.len;
    }

    pub fn put(self: *TestStore, key: []const u8, value: []const u8) Preferences.PutError!void {
        if (key.len == 0 or key.len > 16) return error.InvalidKey;
        if (value.len > 32) return error.ValueTooLarge;
        const entry = self.find(key) orelse self.freeEntry() orelse return error.NoSpaceLeft;
        @memset(&entry.key_buf, 0);
        @memset(&entry.value_buf, 0);
        @memcpy(entry.key_buf[0..key.len], key);
        @memcpy(entry.value_buf[0..value.len], value);
        entry.key_len = key.len;
        entry.value_len = value.len;
        entry.present = true;
    }

    pub fn remove(self: *TestStore, key: []const u8) Preferences.RemoveError!void {
        const entry = self.find(key) orelse return error.NotFound;
        entry.present = false;
    }

    pub fn contains(self: *TestStore, key: []const u8) bool {
        return self.find(key) != null;
    }

    pub fn list(self: *TestStore, allocator: glib.std.mem.Allocator) Preferences.ListError![]Preferences.Entry {
        const entries = allocator.alloc(Preferences.Entry, self.entryCount()) catch return error.OutOfMemory;
        errdefer allocator.free(entries);
        _ = self.copyEntries(entries, 0);
        return entries;
    }

    fn entryCount(self: *TestStore) usize {
        var count: usize = 0;
        for (&self.entries) |*entry| {
            if (!entry.present) continue;
            count += 1;
        }
        return count;
    }

    fn copyEntries(self: *TestStore, out: []Preferences.Entry, start: usize) usize {
        var index = start;
        for (&self.entries) |*entry| {
            if (!entry.present) continue;
            out[index] = .{
                .namespace_len = @intCast(self.namespace_len),
                .key_len = @intCast(entry.key_len),
                .value_type = .blob,
                .value_len = entry.value_len,
            };
            @memcpy(out[index].namespace_buf[0..self.namespace_len], self.namespace());
            @memcpy(out[index].key_buf[0..entry.key_len], entry.key());
            index += 1;
        }
        return index;
    }

    pub fn clear(self: *TestStore) Preferences.ClearError!void {
        for (&self.entries) |*entry| entry.present = false;
    }

    pub fn sync(self: *TestStore) Preferences.SyncError!void {
        _ = self;
    }

    fn find(self: *TestStore, key: []const u8) ?*Entry {
        for (&self.entries) |*entry| {
            if (entry.present and glib.std.mem.eql(u8, entry.key(), key)) return entry;
        }
        return null;
    }

    fn freeEntry(self: *TestStore) ?*Entry {
        for (&self.entries) |*entry| {
            if (!entry.present) return entry;
        }
        return null;
    }
};
