const bk = @import("bk");

const Display = bk.embed.drivers.Display;

pub fn make(comptime platform_ctx: type, comptime platform_grt: type) type {
    _ = platform_ctx;

    const log = platform_grt.std.log.scoped(.bk_raw_colorbar);

    return struct {
        const Self = @This();

        pub const ZuxApp = struct {
            pub const registries = emptyRegistries();
            pub const InitConfig = struct {};
            pub const StartConfig = struct {};

            pub fn init(_: ZuxApp.InitConfig) !ZuxApp {
                return .{};
            }

            pub fn deinit(_: *ZuxApp) void {}

            pub fn start(_: *ZuxApp, _: ZuxApp.StartConfig) !void {}

            pub fn stop(_: *ZuxApp) !void {}
        };

        pub const InitConfig = ZuxApp.InitConfig;
        pub const StartConfig = ZuxApp.StartConfig;
        pub const AppHost = struct {
            allocator: platform_grt.std.mem.Allocator,
            display: ?Display = null,
            pixels: ?[]Display.Rgb = null,

            pub fn start(self: *AppHost) !void {
                const run_task = try platform_grt.task.go("bk/raw_colorbar", .{
                    .min_stack_size = 4096,
                }, platform_grt.task.Routine.init(self, task));
                run_task.detach();
            }

            fn task(self: *AppHost) void {
                while (true) {
                    self.drawOnce() catch |err| {
                        log.err("raw colorbar draw failed: {}", .{err});
                    };
                    platform_grt.time.sleepNanos(@intCast(5 * platform_grt.time.duration.Second));
                    log.info("raw colorbar alive", .{});
                }
            }

            fn drawOnce(self: *AppHost) !void {
                if (self.display == null) {
                    self.display = try bk.embed.display.Rgb.display(.{
                        .allocator = bk.heap.psram_allocator,
                        .max_flush_rows = 64,
                    });
                    try self.display.?.setEnabled(true);
                    try self.display.?.setBrightness(255);
                }

                const display = self.display.?;
                const width_px = display.width();
                const height_px = display.height();
                const count = @as(usize, width_px) * @as(usize, height_px);
                if (self.pixels == null) {
                    self.pixels = try bk.heap.psram_allocator.alloc(Display.Rgb, count);
                }

                const pixels = self.pixels.?;
                for (0..height_px) |y| {
                    for (0..width_px) |x| {
                        pixels[y * @as(usize, width_px) + x] = colorForX(@intCast(x), width_px);
                    }
                }

                try display.drawBitmap(0, 0, width_px, height_px, pixels);
                log.info("raw wrapped display colorbar drawn size={}x{}", .{ width_px, height_px });
            }

            fn deinit(self: *AppHost) void {
                if (self.pixels) |pixels| self.allocator.free(pixels);
                if (self.display) |*display| display.deinit();
                self.* = undefined;
            }
        };

        allocator: platform_grt.std.mem.Allocator,
        zux_app: ZuxApp,
        host: AppHost,

        pub fn init(allocator: platform_grt.std.mem.Allocator, init_config: InitConfig) !Self {
            return .{
                .allocator = allocator,
                .zux_app = try ZuxApp.init(init_config),
                .host = .{ .allocator = allocator },
            };
        }

        pub fn deinit(self: *Self) void {
            self.host.deinit();
            self.zux_app.deinit();
            self.* = undefined;
        }

        pub fn app(self: *Self) *AppHost {
            return &self.host;
        }

        pub fn zux(self: *Self) *ZuxApp {
            return &self.zux_app;
        }
    };
}

fn colorForX(x: u16, width_px: u16) Display.Rgb {
    const stripe = (@as(u32, x) * color_table.len) / width_px;
    return color_table[@intCast(stripe)];
}

const color_table = [_]Display.Rgb{
    Display.rgb(255, 255, 255),
    Display.rgb(255, 255, 0),
    Display.rgb(0, 255, 255),
    Display.rgb(0, 255, 0),
    Display.rgb(255, 0, 255),
    Display.rgb(255, 0, 0),
    Display.rgb(0, 0, 255),
    Display.rgb(0, 0, 0),
};

fn emptyRegistries() EmptyRegistries {
    const empty = EmptyRegistry{};
    return .{
        .single_button = empty,
        .adc_button = empty,
        .display = empty,
        .bt = empty,
        .ledstrip = empty,
        .wifi_sta = empty,
        .audio_system = empty,
        .touch = empty,
        .imu = empty,
        .modem = empty,
        .nfc = empty,
        .wifi_ap = empty,
    };
}

const EmptyRegistries = struct {
    single_button: EmptyRegistry,
    adc_button: EmptyRegistry,
    display: EmptyRegistry,
    bt: EmptyRegistry,
    ledstrip: EmptyRegistry,
    wifi_sta: EmptyRegistry,
    audio_system: EmptyRegistry,
    touch: EmptyRegistry,
    imu: EmptyRegistry,
    modem: EmptyRegistry,
    nfc: EmptyRegistry,
    wifi_ap: EmptyRegistry,
};

const EmptyRegistry = struct {
    len: comptime_int = 0,
    periphs: [0]void = .{},
};
