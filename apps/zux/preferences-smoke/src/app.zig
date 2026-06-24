const embed = @import("embed");
const glib = @import("glib");
const launcher = @import("launcher");

const Preferences = embed.system.Preferences;

fn EmptyRegistry(comptime T: type) type {
    return struct {
        periphs: [0]T = .{},
        len: usize = 0,
    };
}

const EmptyPeriph = struct {
    label: @Type(.enum_literal) = .none,
};

fn MinimalZuxApp(comptime platform_grt: type) type {
    return struct {
        const Self = @This();

        pub const PipelineConfig = struct {
            capacity: usize = 64,
            tick_interval: platform_grt.time.duration.Duration = 10 * platform_grt.time.duration.MilliSecond,
            task_options: glib.task.Options = .{ .min_stack_size = 16 * 1024 },
        };
        pub const PollerConfig = struct {
            poll_interval: platform_grt.time.duration.Duration = 10 * platform_grt.time.duration.MilliSecond,
            task_options: glib.task.Options = .{ .min_stack_size = 8 * 1024 },
        };
        pub const InitConfig = struct {
            allocator: platform_grt.std.mem.Allocator,
            pipeline_config: PipelineConfig = .{},
            poller_config: PollerConfig = .{},
        };
        pub const StartConfig = struct {};
        pub const registries = .{
            .adc_button = EmptyRegistry(EmptyPeriph){},
            .bt = EmptyRegistry(EmptyPeriph){},
            .audio_system = EmptyRegistry(EmptyPeriph){},
            .display = EmptyRegistry(EmptyPeriph){},
            .single_button = EmptyRegistry(EmptyPeriph){},
            .imu = EmptyRegistry(EmptyPeriph){},
            .ledstrip = EmptyRegistry(EmptyPeriph){},
            .modem = EmptyRegistry(EmptyPeriph){},
            .nfc = EmptyRegistry(EmptyPeriph){},
            .switch_output = EmptyRegistry(EmptyPeriph){},
            .pwm = EmptyRegistry(EmptyPeriph){},
            .touch = EmptyRegistry(EmptyPeriph){},
            .wifi_sta = EmptyRegistry(EmptyPeriph){},
            .wifi_ap = EmptyRegistry(EmptyPeriph){},
        };

        allocator: platform_grt.std.mem.Allocator,
        started: bool = false,

        pub fn init(config: InitConfig) !Self {
            return .{
                .allocator = config.allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn start(self: *Self, config: StartConfig) !void {
            _ = config;
            self.started = true;
        }

        pub fn stop(self: *Self) !void {
            self.started = false;
        }
    };
}

pub const TestPlatformCtx = struct {
    pub fn setup() !void {}
    pub fn teardown() void {}

    pub fn preferencesProvider(allocator: glib.std.mem.Allocator) !TestPreferencesProvider {
        _ = allocator;
        return TestPreferencesProvider.init();
    }
};

pub fn make(comptime platform_ctx: type, comptime platform_grt: type) type {
    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = MinimalZuxApp(platform_grt);

        pub const title = "preferences-smoke";
        pub const description = "embed.system.Preferences smoke test.";

        allocator: glib.std.mem.Allocator,
        zux_app: ZuxApp,

        pub fn init(allocator: glib.std.mem.Allocator, base_config: ZuxApp.InitConfig) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            var init_config = base_config;
            init_config.allocator = allocator;
            self.* = .{
                .allocator = allocator,
                .zux_app = try ZuxApp.init(init_config),
            };
            errdefer self.zux_app.deinit();

            try runSmoke(platform_ctx, platform_grt, allocator);
            return self;
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            self.zux_app.deinit();
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn start(self: *Self) !void {
            _ = self;
        }

        pub fn stop(self: *Self) void {
            _ = self;
        }

        pub fn createTestRunner() glib.testing.TestRunner {
            return testRunner(platform_ctx, platform_grt);
        }
    });
}

pub fn testRunner(comptime platform_ctx: type, comptime platform_grt: type) glib.testing.TestRunner {
    const Runner = struct {
        task_options: glib.task.Options = preferencesSmokeTaskOptions(platform_ctx),

        pub fn init(self: *@This(), allocator: platform_grt.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: platform_grt.std.mem.Allocator) bool {
            _ = self;

            runSmoke(platform_ctx, platform_grt, allocator) catch |err| {
                t.logErrorf("preferences smoke failed: {s}", .{@errorName(err)});
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: platform_grt.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

fn preferencesSmokeTaskOptions(comptime platform_ctx: type) glib.task.Options {
    if (comptime @hasDecl(platform_ctx, "preferencesSmokeTaskOptions")) {
        return platform_ctx.preferencesSmokeTaskOptions();
    }
    return .{ .min_stack_size = 24 * 1024 };
}

pub fn run(comptime platform_ctx: type, comptime platform_grt: type) !void {
    try platform_ctx.setup();
    defer platform_ctx.teardown();

    var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_preferences_smoke);
    defer t.deinit();

    t.run("preferences-smoke/nvs-contract", testRunner(platform_ctx, platform_grt));
    if (!t.wait()) return error.TestFailed;
}

fn runSmoke(comptime platform_ctx: type, comptime platform_grt: type, allocator: glib.std.mem.Allocator) !void {
    const log = platform_grt.std.log.scoped(.zux_preferences_smoke);

    var provider_impl = try makePreferencesProvider(platform_ctx, platform_grt, allocator);
    defer deinitIfPresent(&provider_impl);
    const provider = provider_impl.handle();

    const namespace = "zux_pref";
    const key = "smoke";

    var store = try provider.open(namespace, .{ .create = true });
    defer store.deinit();

    try store.clear();
    try store.put(key, "alpha");
    try store.sync();

    const perf_value = [_]u8{'p'} ** 128;
    const perf_iters = 64;
    const write_started_ns = platform_grt.time.instant.now();
    for (0..perf_iters) |_| {
        try store.put("perf", &perf_value);
    }
    try store.sync();
    const write_elapsed_ns = elapsedSince(platform_grt, write_started_ns);

    var perf_buf: [perf_value.len]u8 = undefined;
    const read_started_ns = platform_grt.time.instant.now();
    for (0..perf_iters) |_| {
        const perf_len = try store.get("perf", &perf_buf);
        if (perf_len != perf_value.len) return error.UnexpectedPreferenceValue;
    }
    const read_elapsed_ns = elapsedSince(platform_grt, read_started_ns);
    log.info(
        "preferences perf namespace={s} bytes={} write={}ops/{}ms read={}ops/{}ms",
        .{
            namespace,
            perf_value.len * perf_iters,
            perf_iters,
            nsToMs(write_elapsed_ns),
            perf_iters,
            nsToMs(read_elapsed_ns),
        },
    );

    var buf: [32]u8 = undefined;
    var len = try store.get(key, &buf);
    try expectEqualStrings(platform_grt, "alpha", buf[0..len]);
    if (!store.contains(key)) return error.PreferenceMissingAfterPut;

    try store.put(key, "beta-value");
    len = try store.get(key, &buf);
    try expectEqualStrings(platform_grt, "beta-value", buf[0..len]);

    const allocated = try store.getAlloc(allocator, key);
    defer allocator.free(allocated);
    try expectEqualStrings(platform_grt, "beta-value", allocated);

    const entries = try store.list(allocator);
    defer allocator.free(entries);
    if (!containsEntry(entries, namespace, key)) return error.PreferenceListMissingKey;
    if (!containsEntry(entries, namespace, "perf")) return error.PreferenceListMissingKey;

    const namespaces = try provider.list(allocator);
    defer allocator.free(namespaces);
    if (!containsNamespace(namespaces, namespace)) return error.PreferenceListMissingNamespace;

    var small: [4]u8 = undefined;
    try expectError(platform_grt, error.BufferTooSmall, store.get(key, &small));

    try store.remove(key);
    if (store.contains(key)) return error.PreferencePresentAfterRemove;
    try expectError(platform_grt, error.NotFound, store.get(key, &buf));

    var reopened = try provider.open(namespace, .{ .create = false });
    defer reopened.deinit();
    try reopened.put(key, "reopened");
    len = try reopened.get(key, &buf);
    try expectEqualStrings(platform_grt, "reopened", buf[0..len]);
    try reopened.clear();

    log.info("preferences smoke passed namespace={s}", .{namespace});
}

fn elapsedSince(comptime platform_grt: type, started_ns: glib.time.instant.Time) glib.time.duration.Duration {
    return platform_grt.time.instant.sub(platform_grt.time.instant.now(), started_ns);
}

fn nsToMs(ns: glib.time.duration.Duration) u64 {
    return @intCast(@divTrunc(ns, glib.time.duration.MilliSecond));
}

fn containsNamespace(namespaces: []const Preferences.Namespace, name: []const u8) bool {
    for (namespaces) |namespace| {
        if (glib.std.mem.eql(u8, namespace.name(), name)) return true;
    }
    return false;
}

fn containsEntry(entries: []const Preferences.Entry, namespace: []const u8, key: []const u8) bool {
    for (entries) |entry| {
        if (glib.std.mem.eql(u8, entry.namespace(), namespace) and
            glib.std.mem.eql(u8, entry.key(), key))
        {
            return true;
        }
    }
    return false;
}

fn makePreferencesProvider(comptime platform_ctx: type, comptime platform_grt: type, allocator: glib.std.mem.Allocator) !PreferencesProviderType(platform_ctx, platform_grt) {
    if (comptime @hasDecl(platform_ctx, "preferencesProvider")) {
        return try platform_ctx.preferencesProvider(allocator);
    }
    return TestPreferencesProvider.init();
}

fn PreferencesProviderType(comptime platform_ctx: type, comptime platform_grt: type) type {
    _ = platform_grt;
    if (comptime @hasDecl(platform_ctx, "preferencesProvider")) {
        const Fn = @TypeOf(platform_ctx.preferencesProvider);
        const ret = @typeInfo(Fn).@"fn".return_type orelse
            @compileError("preferencesProvider must return a provider implementation");
        return switch (@typeInfo(ret)) {
            .error_union => |info| info.payload,
            else => ret,
        };
    }
    return TestPreferencesProvider;
}

fn deinitIfPresent(value: anytype) void {
    const Ptr = @TypeOf(value);
    const Impl = @typeInfo(Ptr).pointer.child;
    if (comptime @hasDecl(Impl, "deinit")) value.deinit();
}

fn expectEqualStrings(comptime platform_grt: type, expected: []const u8, actual: []const u8) !void {
    if (!platform_grt.std.mem.eql(u8, expected, actual)) return error.UnexpectedPreferenceValue;
}

fn expectError(comptime platform_grt: type, expected: anyerror, result: anytype) !void {
    _ = platform_grt;
    if (result) |_| {
        return error.ExpectedPreferenceError;
    } else |err| {
        if (err != expected) return err;
    }
}

const TestPreferencesProvider = struct {
    stores: [2]TestStore,

    fn init() TestPreferencesProvider {
        return .{
            .stores = .{
                TestStore.empty(),
                TestStore.empty(),
            },
        };
    }

    pub fn handle(self: *TestPreferencesProvider) Preferences.Provider {
        return Preferences.Provider.init(self);
    }

    pub fn open(self: *TestPreferencesProvider, namespace: []const u8, options: Preferences.OpenOptions) Preferences.OpenError!Preferences.Store {
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
        return error.OutOfMemory;
    }

    pub fn list(self: *TestPreferencesProvider, allocator: glib.std.mem.Allocator) Preferences.ListError![]Preferences.Namespace {
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
        const key_buf_len = 16;
        const value_buf_len = 128;

        key_buf: [key_buf_len]u8 = [_]u8{0} ** key_buf_len,
        key_len: usize = 0,
        value_buf: [value_buf_len]u8 = [_]u8{0} ** value_buf_len,
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

    fn namespace(self: *const TestStore) []const u8 {
        return self.namespace_buf[0..self.namespace_len];
    }

    fn setNamespace(self: *TestStore, namespace_value: []const u8) !void {
        if (namespace_value.len == 0 or namespace_value.len >= self.namespace_buf.len) return error.InvalidNamespace;
        @memset(&self.namespace_buf, 0);
        self.namespace_len = namespace_value.len;
        @memcpy(self.namespace_buf[0..namespace_value.len], namespace_value);
        self.active = true;
    }

    pub fn get(self: *TestStore, key: []const u8, out: []u8) Preferences.GetError!usize {
        const entry = self.find(key) orelse return error.NotFound;
        const value = entry.value();
        if (out.len < value.len) return error.BufferTooSmall;
        @memcpy(out[0..value.len], value);
        return value.len;
    }

    pub fn put(self: *TestStore, key: []const u8, value: []const u8) Preferences.PutError!void {
        if (key.len == 0 or key.len >= Entry.key_buf_len) return error.InvalidKey;
        if (value.len > Entry.value_buf_len) return error.ValueTooLarge;
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

        var index: usize = 0;
        for (&self.entries) |*entry| {
            if (!entry.present) continue;
            entries[index] = .{
                .namespace_len = @intCast(self.namespace_len),
                .key_len = @intCast(entry.key_len),
                .value_type = .blob,
                .value_len = entry.value_len,
            };
            @memcpy(entries[index].namespace_buf[0..self.namespace_len], self.namespace());
            @memcpy(entries[index].key_buf[0..entry.key_len], entry.key());
            index += 1;
        }
        return entries;
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

    fn entryCount(self: *TestStore) usize {
        var count: usize = 0;
        for (&self.entries) |*entry| {
            if (!entry.present) continue;
            count += 1;
        }
        return count;
    }
};
