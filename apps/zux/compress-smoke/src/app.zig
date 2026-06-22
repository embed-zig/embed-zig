const glib = @import("glib");
const launcher = @import("launcher");

const input = "hello compress";
const raw = [_]u8{ 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x48, 0xce, 0xcf, 0x2d, 0x28, 0x4a, 0x2d, 0x2e, 0x06, 0x00 };
const zlib = [_]u8{ 0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x48, 0xce, 0xcf, 0x2d, 0x28, 0x4a, 0x2d, 0x2e, 0x06, 0x00, 0x29, 0x38, 0x05, 0xa1 };
const gzip = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x13, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x48, 0xce, 0xcf, 0x2d, 0x28, 0x4a, 0x2d, 0x2e, 0x06, 0x00, 0xcd, 0x75, 0x7e, 0x84, 0x0e, 0x00, 0x00, 0x00 };

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

        pub const title = "compress-smoke";
        pub const description = "Runtime-bound glib.compress smoke test.";

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
                t.logErrorf("compress smoke failed: {s}", .{@errorName(err)});
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

    var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_compress_smoke);
    defer t.deinit();

    t.run("compress-smoke/inflate", testRunner(platform_ctx, platform_grt));
    if (!t.wait()) return error.TestFailed;
}

fn runSmoke(comptime platform_ctx: type, comptime platform_grt: type, allocator: platform_grt.std.mem.Allocator) !void {
    _ = platform_ctx;
    const log = platform_grt.std.log.scoped(.zux_compress_smoke);
    const Compress = RuntimeCompress(platform_grt);

    log.info("inflating raw payload", .{});
    try expectInflate(platform_grt, Compress, .raw, &raw);

    log.info("inflating zlib payload", .{});
    try expectInflate(platform_grt, Compress, .zlib, &zlib);

    log.info("inflating gzip payload", .{});
    try expectOptionalInflate(platform_grt, Compress, .gzip, &gzip);

    try expectOutputTooSmall(Compress);
    try expectInflateAlloc(platform_grt, Compress, allocator);
    try expectInflateStream(platform_grt, Compress);
    log.info("compress smoke passed", .{});
}

fn expectInflate(
    comptime platform_grt: type,
    comptime Compress: type,
    container: Compress.Container,
    compressed: []const u8,
) !void {
    var out: [input.len]u8 = undefined;
    const len = try Compress.inflate(container, compressed, &out);
    if (len != input.len) return error.UnexpectedLength;
    if (!platform_grt.std.mem.eql(u8, input, out[0..len])) return error.UnexpectedData;
}

fn expectOutputTooSmall(comptime Compress: type) !void {
    var out: [input.len - 1]u8 = undefined;
    if (Compress.inflate(.raw, &raw, &out)) |_| {
        return error.ExpectedOutputTooSmall;
    } else |err| switch (err) {
        error.OutputTooSmall => {},
        else => return err,
    }
}

fn expectOptionalInflate(
    comptime platform_grt: type,
    comptime Compress: type,
    container: Compress.Container,
    compressed: []const u8,
) !void {
    expectInflate(platform_grt, Compress, container, compressed) catch |err| switch (err) {
        error.Unsupported => return,
        else => return err,
    };
}

fn expectInflateAlloc(
    comptime platform_grt: type,
    comptime Compress: type,
    allocator: platform_grt.std.mem.Allocator,
) !void {
    const out = try Compress.inflateAlloc(allocator, .zlib, &zlib, input.len);
    defer allocator.free(out);

    if (!platform_grt.std.mem.eql(u8, input, out)) return error.UnexpectedAllocData;
}

fn expectInflateStream(
    comptime platform_grt: type,
    comptime Compress: type,
) !void {
    if (comptime !Compress.supports_stream) return;

    const Sink = struct {
        buffer: [input.len]u8 = undefined,
        len: usize = 0,

        pub fn write(self: *@This(), data: []const u8) !void {
            if (self.len + data.len > self.buffer.len) return error.StreamOverflow;
            platform_grt.std.mem.copyForwards(u8, self.buffer[self.len..][0..data.len], data);
            self.len += data.len;
        }
    };

    var sink = Sink{};
    const len = try Compress.inflateStream(.zlib, &zlib, &sink);
    if (len != input.len or sink.len != input.len) return error.UnexpectedStreamLength;
    if (!platform_grt.std.mem.eql(u8, input, sink.buffer[0..sink.len])) return error.UnexpectedStreamData;
}

fn RuntimeCompress(comptime platform_grt: type) type {
    if (!@hasDecl(platform_grt, "compress")) {
        @compileError("compress-smoke requires platform_grt.compress");
    }
    if (platform_grt.compress == void) {
        @compileError("compress-smoke requires a non-void platform_grt.compress");
    }
    if (comptime @hasDecl(platform_grt.compress, "impl")) {
        return glib.compress.make(platform_grt.std, platform_grt.compress.impl);
    }
    return platform_grt.compress;
}
