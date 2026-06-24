const glib = @import("glib");
const glib_empty_zux_app = @import("glib_empty_zux_app");
const launcher = @import("launcher");

pub fn make(comptime platform_ctx: type, comptime platform_grt: type) type {
    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = glib_empty_zux_app.make(platform_grt);

        pub const title = "system-smoke";
        pub const description = "Runtime system information smoke test.";

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

            try runSmoke(platform_ctx, platform_grt);
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
        pub fn init(self: *@This(), allocator: platform_grt.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: platform_grt.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            runSmoke(platform_ctx, platform_grt) catch |err| {
                t.logErrorf("system smoke failed: {s}", .{@errorName(err)});
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

pub fn run(comptime platform_ctx: type, comptime platform_grt: type) !void {
    try platform_ctx.setup();
    defer platform_ctx.teardown();

    var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_system_smoke);
    defer t.deinit();

    t.run("system-smoke/cpu", testRunner(platform_ctx, platform_grt));
    if (!t.wait()) return error.TestFailed;
}

fn runSmoke(comptime platform_ctx: type, comptime platform_grt: type) !void {
    _ = platform_ctx;

    const log = platform_grt.std.log.scoped(.zux_system_smoke);
    const cpu_count = try platform_grt.system.cpuCount();
    if (cpu_count == 0) return error.InvalidCpuCount;

    try smokeStats(platform_grt);
    try smokeTaskRuntimeSnapshot(platform_grt);

    log.info("system smoke passed cpu_count={d}", .{cpu_count});
}

fn smokeStats(comptime platform_grt: type) !void {
    const log = platform_grt.std.log.scoped(.zux_system_smoke);

    var cpu_stats: platform_grt.system.CpuStats = .{};
    platform_grt.system.readCpuStats(&cpu_stats) catch |err| switch (err) {
        error.Unsupported => {
            log.info("system cpu stats unsupported", .{});
        },
        else => return err,
    };
    if (cpu_stats.core_count > platform_grt.system.max_cpu_cores) return error.InvalidCpuStats;
    for (cpu_stats.cores[0..cpu_stats.core_count]) |core| {
        if (core.usage_percent > 100) return error.InvalidCpuStats;
    }

    var memory_stats: platform_grt.system.MemoryStats = .{};
    platform_grt.system.readMemoryStats(&memory_stats) catch |err| switch (err) {
        error.Unsupported => {
            log.info("system memory stats unsupported", .{});
        },
        else => return err,
    };
    if (memory_stats.heap_total != 0 and memory_stats.heap_free > memory_stats.heap_total) return error.InvalidMemoryStats;
    if (memory_stats.internal_total != 0 and memory_stats.internal_free > memory_stats.internal_total) return error.InvalidMemoryStats;
    if (memory_stats.psram_total != 0 and memory_stats.psram_free > memory_stats.psram_total) return error.InvalidMemoryStats;

    var task_stats: platform_grt.system.TaskStats = .{};
    platform_grt.system.readTaskStats(&task_stats) catch |err| switch (err) {
        error.Unsupported => {
            log.info("system task stats unsupported", .{});
            return;
        },
        else => return err,
    };
    if (task_stats.count == 0) return error.InvalidTaskStats;
}

fn smokeTaskRuntimeSnapshot(comptime platform_grt: type) !void {
    if (comptime !@hasDecl(platform_grt.system, "TaskRuntimeEntry")) return;
    if (comptime !@hasDecl(platform_grt.system, "taskRuntimeSnapshot")) return;

    var entries: [8]platform_grt.system.TaskRuntimeEntry = undefined;
    const len = platform_grt.system.taskRuntimeSnapshot(entries[0..]);
    if (len > entries.len) return error.InvalidTaskRuntimeSnapshot;
}
