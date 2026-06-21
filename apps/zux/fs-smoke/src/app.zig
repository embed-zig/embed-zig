const glib = @import("glib");
const launcher = @import("launcher");

const smoke_payload = "hello from zux fs smoke";
const stream_payload = "streamed zux fs payload across small chunks";
const speed_test_bytes: usize = 64 * 1024;
const speed_chunk_bytes: usize = 1024;

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

pub fn make(comptime platform_ctx: type, comptime platform_grt: type) type {
    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = MinimalZuxApp(platform_grt);

        pub const title = "fs-smoke";
        pub const description = "Runtime-bound glib.fs smoke test.";

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
        task_options: glib.task.Options = .{ .min_stack_size = 24 * 1024 },

        pub fn init(self: *@This(), allocator: platform_grt.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: platform_grt.std.mem.Allocator) bool {
            _ = self;

            runSmoke(platform_ctx, platform_grt, allocator) catch |err| {
                t.logErrorf("fs smoke failed: {s}", .{@errorName(err)});
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

    var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_fs_smoke);
    defer t.deinit();

    t.run("fs-smoke/read-write-delete", testRunner(platform_ctx, platform_grt));
    if (!t.wait()) return error.TestFailed;
}

fn runSmoke(comptime platform_ctx: type, comptime platform_grt: type, allocator: platform_grt.std.mem.Allocator) !void {
    const log = platform_grt.std.log.scoped(.zux_fs_smoke);
    const Fs = RuntimeFs(platform_grt);
    const mounted_storage = try mountStorageIfAvailable(platform_ctx);
    defer if (mounted_storage) unmountStorageIfAvailable(platform_ctx);

    const path = comptime smokePath(platform_ctx, "zux-fs-smoke.txt");
    const stream_path = comptime smokePath(platform_ctx, "zux-fs-smoke-stream.txt");
    Fs.deleteFile(path) catch {};
    Fs.deleteFile(stream_path) catch {};
    defer Fs.deleteFile(path) catch {};
    defer Fs.deleteFile(stream_path) catch {};

    log.info("writing fs smoke payload to {s}", .{path});
    try Fs.writeFile(path, smoke_payload);

    const stat = try Fs.stat(path);
    if (stat.kind != .file) return error.ExpectedFile;
    if (stat.size != smoke_payload.len) return error.UnexpectedSize;

    const data = try Fs.readFileAlloc(allocator, path, 256);
    defer allocator.free(data);
    if (!platform_grt.std.mem.eql(u8, data, smoke_payload)) return error.UnexpectedData;

    try Fs.deleteFile(path);
    if (Fs.openFile(path, .{})) |file| {
        file.deinit();
        return error.ExpectedDeletedFile;
    } else |err| switch (err) {
        error.NotFound => {},
        else => return err,
    }

    log.info("streaming fs smoke payload to {s}", .{stream_path});
    try runStreamingSmoke(platform_grt, Fs, stream_path);

    try runSpeedSmoke(platform_ctx, platform_grt, Fs);
    try runEnsureParentDirsSmoke(platform_ctx, platform_grt, Fs, allocator);
    log.info("fs smoke passed", .{});
}

fn runStreamingSmoke(comptime platform_grt: type, comptime Fs: type, path: []const u8) !void {
    var file = try Fs.createFile(path, .{
        .read = true,
        .truncate = true,
        .exclusive = false,
    });
    defer file.deinit();

    inline for (.{
        "streamed ",
        "zux ",
        "fs ",
        "payload ",
        "across ",
        "small ",
        "chunks",
    }) |chunk| {
        var written: usize = 0;
        while (written < chunk.len) {
            const n = try file.write(chunk[written..]);
            if (n == 0) return error.UnexpectedWrite;
            written += n;
        }
    }
    try file.sync();

    const pos = try file.seek(0, .start);
    if (pos != 0) return error.UnexpectedPosition;

    var data: [stream_payload.len]u8 = undefined;
    var total: usize = 0;
    var scratch: [5]u8 = undefined;
    while (total < data.len) {
        const read_len = @min(scratch.len, data.len - total);
        const n = try file.read(scratch[0..read_len]);
        if (n == 0) return error.UnexpectedEof;
        @memcpy(data[total..][0..n], scratch[0..n]);
        total += n;
    }
    if (!platform_grt.std.mem.eql(u8, &data, stream_payload)) return error.UnexpectedStreamData;

    const eof = try file.read(&scratch);
    if (eof != 0) return error.ExpectedEof;
}

fn runSpeedSmoke(
    comptime platform_ctx: type,
    comptime platform_grt: type,
    comptime Fs: type,
) !void {
    const log = platform_grt.std.log.scoped(.zux_fs_smoke);
    const path = comptime smokePath(platform_ctx, "fsbench.bin");
    Fs.deleteFile(path) catch {};
    defer Fs.deleteFile(path) catch {};

    var chunk: [speed_chunk_bytes]u8 = undefined;
    fillSpeedChunk(&chunk);
    const expected_checksum = checksumForRepeatedChunk(&chunk, speed_test_bytes / chunk.len);

    log.info("fs speed write start path={s} bytes={}", .{ path, speed_test_bytes });
    const write_started = platform_grt.time.instant.now();
    var written_total: usize = 0;
    {
        var write_file = try Fs.createFile(path, .{
            .read = false,
            .truncate = true,
            .exclusive = false,
        });
        defer write_file.deinit();

        while (written_total < speed_test_bytes) {
            const write_len = @min(chunk.len, speed_test_bytes - written_total);
            var written_chunk: usize = 0;
            while (written_chunk < write_len) {
                const n = try write_file.write(chunk[written_chunk..write_len]);
                if (n == 0) return error.UnexpectedWrite;
                written_chunk += n;
            }
            written_total += write_len;
        }
        try write_file.sync();
    }
    const write_ms = durationMs(platform_grt, platform_grt.time.instant.now() - write_started);
    log.info("fs speed write done bytes={} elapsed_ms={} kib_s={}", .{
        written_total,
        write_ms,
        kibPerSecond(written_total, write_ms),
    });

    log.info("fs speed read start path={s} bytes={}", .{ path, speed_test_bytes });
    const read_started = platform_grt.time.instant.now();
    var read_file = try Fs.openFile(path, .{ .mode = .read_only });
    defer read_file.deinit();

    var read_total: usize = 0;
    var read_checksum: u32 = 0;
    while (true) {
        var read_buf: [speed_chunk_bytes]u8 = undefined;
        const n = try read_file.read(&read_buf);
        if (n == 0) break;
        read_total += n;
        read_checksum +%= checksumBytes(read_buf[0..n]);
    }
    const read_ms = durationMs(platform_grt, platform_grt.time.instant.now() - read_started);
    if (read_total != speed_test_bytes) return error.UnexpectedSpeedReadSize;
    if (read_checksum != expected_checksum) return error.UnexpectedSpeedReadChecksum;
    log.info("fs speed read done bytes={} elapsed_ms={} kib_s={}", .{
        read_total,
        read_ms,
        kibPerSecond(read_total, read_ms),
    });
}

fn runEnsureParentDirsSmoke(
    comptime platform_ctx: type,
    comptime platform_grt: type,
    comptime Fs: type,
    allocator: platform_grt.std.mem.Allocator,
) !void {
    const log = platform_grt.std.log.scoped(.zux_fs_smoke);
    const root_path = comptime smokePath(platform_ctx, "fsd");
    const nested_path = comptime smokePath(platform_ctx, "fsd/a/p.txt");

    Fs.deleteFile(nested_path) catch {};
    defer Fs.deleteFile(nested_path) catch {};

    log.info("ensuring fs smoke parent dirs root={s} file={s}", .{ root_path, nested_path });
    Fs.ensureParentDirs(root_path, nested_path) catch |err| {
        log.err("ensure parent dirs failed: {s}", .{@errorName(err)});
        return err;
    };
    log.info("writing nested fs smoke payload to {s}", .{nested_path});
    Fs.writeFile(nested_path, "nested payload") catch |err| {
        log.err("write nested fs smoke payload failed: {s}", .{@errorName(err)});
        return err;
    };

    const data = Fs.readFileAlloc(allocator, nested_path, 64) catch |err| {
        log.err("read nested fs smoke payload failed: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(data);
    if (!platform_grt.std.mem.eql(u8, data, "nested payload")) return error.UnexpectedNestedData;
}

fn fillSpeedChunk(chunk: []u8) void {
    for (chunk, 0..) |*byte, i| {
        byte.* = @intCast((i * 31 + 17) & 0xff);
    }
}

fn checksumForRepeatedChunk(chunk: []const u8, repeat_count: usize) u32 {
    const chunk_checksum = checksumBytes(chunk);
    var total: u32 = 0;
    var i: usize = 0;
    while (i < repeat_count) : (i += 1) {
        total +%= chunk_checksum;
    }
    return total;
}

fn checksumBytes(bytes: []const u8) u32 {
    var total: u32 = 0;
    for (bytes) |byte| {
        total +%= byte;
    }
    return total;
}

fn durationMs(comptime platform_grt: type, duration: u64) u64 {
    return @divTrunc(duration, platform_grt.time.duration.MilliSecond);
}

fn kibPerSecond(bytes: usize, elapsed_ms: u64) u64 {
    if (elapsed_ms == 0) return 0;
    return @divTrunc(@as(u64, @intCast(bytes)) * 1000, elapsed_ms * 1024);
}

fn RuntimeFs(comptime platform_grt: type) type {
    if (comptime @hasDecl(platform_grt, "fs") and @hasDecl(platform_grt.fs, "impl")) {
        return glib.fs.make(platform_grt.std, platform_grt.fs.impl);
    }
    return platform_grt.fs;
}

fn smokePath(comptime platform_ctx: type, comptime name: []const u8) []const u8 {
    if (comptime @hasDecl(platform_ctx, "fs") and @hasDecl(platform_ctx.fs, "hasStoragePartition")) {
        if (platform_ctx.fs.hasStoragePartition()) {
            const storage_path = if (@hasDecl(platform_ctx.fs, "storage_path"))
                platform_ctx.fs.storage_path
            else
                "/storage";
            return storage_path ++ "/" ++ name;
        }
        return name ++ ".tmp";
    }
    return name ++ ".tmp";
}

fn mountStorageIfAvailable(comptime platform_ctx: type) !bool {
    if (comptime @hasDecl(platform_ctx, "fs") and @hasDecl(platform_ctx.fs, "mountStorage")) {
        if (!platform_ctx.fs.hasStoragePartition()) return false;
        try platform_ctx.fs.mountStorage();
        return true;
    }
    return false;
}

fn unmountStorageIfAvailable(comptime platform_ctx: type) void {
    if (comptime @hasDecl(platform_ctx, "fs") and @hasDecl(platform_ctx.fs, "unmountStorage")) {
        platform_ctx.fs.unmountStorage();
    }
}
