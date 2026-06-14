const glib = @import("glib");
const launcher = @import("launcher");

const archive_checksum = "archive-smoke-v1";
const alpha_payload = "alpha archive payload";
const beta_payload = "beta payload in nested dir";
const gamma_payload = [_]u8{ 1, 2, 3, 4, 5 };
const archive_payload_len = alpha_payload.len + beta_payload.len + gamma_payload.len;
const archive_file_count = 3;
const archive_zlib = [_]u8{
    0x78, 0xda, 0xed, 0xd4, 0x4b, 0x0e, 0x82, 0x30, 0x14, 0x40, 0xd1, 0xfa,
    0xdb, 0x47, 0x57, 0x80, 0x15, 0xf9, 0xac, 0xe7, 0x21, 0x8d, 0x90, 0x00,
    0x1a, 0xa8, 0x46, 0x77, 0x2f, 0x60, 0x8c, 0x91, 0x89, 0x23, 0x30, 0x86,
    0x7b, 0x26, 0xaf, 0xe9, 0xa4, 0x83, 0xf6, 0x56, 0x8a, 0x73, 0x26, 0x9e,
    0xbb, 0x39, 0x35, 0x1e, 0xd3, 0x8a, 0x82, 0xa0, 0x9f, 0xad, 0xe1, 0x34,
    0xc6, 0x0f, 0xdf, 0xeb, 0x7e, 0x3f, 0x0e, 0x63, 0xa3, 0xb4, 0x51, 0x13,
    0xb8, 0x34, 0x4e, 0xea, 0xf6, 0x48, 0x35, 0x4f, 0xd2, 0xdd, 0xbf, 0x96,
    0xfa, 0x90, 0xe5, 0x57, 0xab, 0xcf, 0x72, 0x2f, 0x4e, 0x92, 0x2a, 0xcc,
    0x45, 0x65, 0x1b, 0x67, 0xd3, 0x6d, 0x62, 0xdd, 0x78, 0xbf, 0xc0, 0xd7,
    0xfe, 0xf7, 0xfe, 0x67, 0xff, 0x3b, 0x13, 0xc5, 0x11, 0xfd, 0x4f, 0xa1,
    0xbb, 0xf8, 0x57, 0xf6, 0x3a, 0xaf, 0xf4, 0xf3, 0x3d, 0xe8, 0x34, 0xaf,
    0x69, 0x63, 0x46, 0xfd, 0x1f, 0xa5, 0x2c, 0xc5, 0x4b, 0xf2, 0xea, 0x27,
    0xfd, 0x9b, 0x70, 0xd8, 0x7f, 0x4c, 0xff, 0xd3, 0x58, 0x2c, 0x57, 0xeb,
    0x0d, 0x19, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xc0, 0xdf, 0x7b, 0x00, 0x7d, 0x82, 0x45, 0xf1,
};

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
            spawn_config: platform_grt.std.Thread.SpawnConfig = .{},
        };
        pub const PollerConfig = struct {
            poll_interval: platform_grt.time.duration.Duration = 10 * platform_grt.time.duration.MilliSecond,
            spawn_config: platform_grt.std.Thread.SpawnConfig = .{},
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

        pub const title = "archive-smoke";
        pub const description = "Runtime-bound glib.archive smoke test.";

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
        pub fn init(self: *@This(), allocator: platform_grt.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: platform_grt.std.mem.Allocator) bool {
            _ = self;

            runSmoke(platform_ctx, platform_grt, allocator) catch |err| {
                t.logErrorf("archive smoke failed: {s}", .{@errorName(err)});
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

    var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_archive_smoke);
    defer t.deinit();

    t.run("archive-smoke/extract", testRunner(platform_ctx, platform_grt));
    if (!t.wait()) return error.TestFailed;
}

fn runSmoke(comptime platform_ctx: type, comptime platform_grt: type, allocator: platform_grt.std.mem.Allocator) !void {
    const log = platform_grt.std.log.scoped(.zux_archive_smoke);
    const Fs = RuntimeFs(platform_grt);
    const Archive = glib.archive.extract.make(platform_grt);
    const mounted_storage = try mountStorageIfAvailable(platform_ctx);
    defer if (mounted_storage) unmountStorageIfAvailable(platform_ctx);

    const root_path = comptime smokeRootPath(platform_ctx);
    try makeDirIfNeeded(Fs, root_path);
    cleanupExtractedFiles(Fs, root_path);
    defer cleanupExtractedFiles(Fs, root_path);

    var archive = Archive.init(allocator);

    log.info("loading archive smoke file", .{});
    const beta = try archive.loadFile(&archive_zlib, "nested/beta.txt", 128);
    defer allocator.free(beta);
    if (!platform_grt.std.mem.eql(u8, beta, beta_payload)) return error.UnexpectedLoadedFile;

    log.info("collecting archive smoke suffix matches", .{});
    const txt_files = try archive.collectFilesBySuffix(&archive_zlib, ".txt", 2);
    defer archive.freeCollectedFiles(txt_files);
    if (txt_files.len != 2) return error.UnexpectedCollectedFileCount;
    try expectCollected(platform_grt, txt_files, "alpha.txt", alpha_payload);
    try expectCollected(platform_grt, txt_files, "nested/beta.txt", beta_payload);

    log.info("extracting archive smoke payload to {s}", .{root_path});
    const first_extract = try archive.extract(.{
        .checksum = archive_checksum,
        .archive_zlib = &archive_zlib,
        .path = root_path,
        .force_clean = true,
        .expected_payload_len = archive_payload_len,
        .expected_file_count = archive_file_count,
    }, NoopProgress{});
    if (!first_extract) return error.ExpectedArchiveExtract;

    try expectFile(platform_grt, Fs, allocator, root_path, "alpha.txt", alpha_payload);
    try expectFile(platform_grt, Fs, allocator, root_path, "nested/beta.txt", beta_payload);
    try expectFile(platform_grt, Fs, allocator, root_path, "nested/gamma.bin", &gamma_payload);

    const second_extract = try archive.extract(.{
        .checksum = archive_checksum,
        .archive_zlib = &archive_zlib,
        .path = root_path,
        .expected_payload_len = archive_payload_len,
        .expected_file_count = archive_file_count,
    }, NoopProgress{});
    if (second_extract) return error.ExpectedArchiveAlreadyCurrent;

    log.info("archive smoke passed", .{});
}

const NoopProgress = struct {
    pub fn event(_: NoopProgress, _: anytype) void {}
};

fn expectCollected(comptime platform_grt: type, files: anytype, path: []const u8, data: []const u8) !void {
    for (files) |file| {
        if (platform_grt.std.mem.eql(u8, file.path, path)) {
            if (!platform_grt.std.mem.eql(u8, file.data, data)) return error.UnexpectedCollectedData;
            return;
        }
    }
    return error.ExpectedCollectedFile;
}

fn expectFile(
    comptime platform_grt: type,
    comptime Fs: type,
    allocator: platform_grt.std.mem.Allocator,
    root_path: []const u8,
    rel_path: []const u8,
    expected: []const u8,
) !void {
    var path_buf: [192]u8 = undefined;
    const path = try glib.path.join(&path_buf, root_path, rel_path);
    const data = try Fs.readFileAlloc(allocator, path, 128);
    defer allocator.free(data);
    if (!platform_grt.std.mem.eql(u8, data, expected)) return error.UnexpectedExtractedFile;
}

fn cleanupExtractedFiles(comptime Fs: type, root_path: []const u8) void {
    deleteFile(Fs, root_path, glib.archive.extract.checksum_file_name);
    deleteFile(Fs, root_path, "alpha.txt");
    deleteFile(Fs, root_path, "nested/beta.txt");
    deleteFile(Fs, root_path, "nested/gamma.bin");
}

fn deleteFile(comptime Fs: type, root_path: []const u8, rel_path: []const u8) void {
    var path_buf: [192]u8 = undefined;
    const path = glib.path.join(&path_buf, root_path, rel_path) catch return;
    Fs.deleteFile(path) catch {};
}

fn makeDirIfNeeded(comptime Fs: type, path: []const u8) !void {
    Fs.makeDir(path) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };
}

fn RuntimeFs(comptime platform_grt: type) type {
    if (comptime @hasDecl(platform_grt, "fs") and @hasDecl(platform_grt.fs, "impl")) {
        return glib.fs.make(platform_grt.std, platform_grt.fs.impl);
    }
    return platform_grt.fs;
}

fn smokeRootPath(comptime platform_ctx: type) []const u8 {
    if (comptime @hasDecl(platform_ctx, "fs") and @hasDecl(platform_ctx.fs, "hasStoragePartition")) {
        if (platform_ctx.fs.hasStoragePartition()) {
            const storage_path = if (@hasDecl(platform_ctx.fs, "storage_path"))
                platform_ctx.fs.storage_path
            else
                "/storage";
            return storage_path ++ "/zux-archive-smoke";
        }
    }
    return "/tmp/zux-archive-smoke";
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
