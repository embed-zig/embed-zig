const glib = @import("glib");
const launcher = @import("launcher");
const testing = @import("glib").testing;

pub fn make(comptime platform_grt: type) type {
    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = EmptyZuxApp(platform_grt);

        allocator: ZuxApp.Allocator,
        zux_app: ZuxApp,

        pub fn init(allocator: ZuxApp.Allocator, init_config: ZuxApp.InitConfig) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .zux_app = try ZuxApp.init(init_config),
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            self.zux_app.deinit();
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn createTestRunner() glib.testing.TestRunner {
            const Runner = struct {
                pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
                    _ = self;
                    _ = allocator;
                }

                pub fn run(self: *@This(), t: *testing.T, allocator: glib.std.mem.Allocator) bool {
                    _ = self;
                    _ = allocator;

                    t.timeout(240 * glib.time.duration.Second);
                    t.run("std/unit", glib.std.test_runner.unit.make(platform_grt.std));
                    return t.wait();
                }

                pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
                    _ = self;
                    _ = allocator;
                }
            };

            const Holder = struct {
                var runner: Runner = .{};
            };
            return testing.TestRunner.make(Runner).new(&Holder.runner);
        }
    });
}

pub fn run(comptime platform_ctx: type, comptime platform_grt: type) !void {
    const Launcher = make(platform_grt);
    const log = platform_grt.std.log.scoped(.compat_tests);

    try platform_ctx.setup();
    defer platform_ctx.teardown();

    log.info("starting embed unit runner", .{});

    var runner = testing.T.new(platform_grt.std, platform_grt.time, .compat_tests);
    defer runner.deinit();

    runner.run("std/unit", Launcher.createTestRunner());
    const passed = runner.wait();
    log.info("embed unit runner finished", .{});
    if (!passed) return error.TestsFailed;
}

fn EmptyZuxApp(comptime platform_grt: type) type {
    const allocator_type = platform_grt.std.mem.Allocator;
    const EmptyRegistry = struct {
        periphs: [0]u8 = .{},
        len: usize = 0,
    };

    return struct {
        pub const Allocator = allocator_type;
        pub const InitConfig = struct {
            allocator: Allocator,
        };
        pub const StartConfig = struct {};
        pub const PeriphLabel = enum { none };
        pub const registries = .{
            .adc_button = EmptyRegistry{},
            .gpio_button = EmptyRegistry{},
            .imu = EmptyRegistry{},
            .ledstrip = EmptyRegistry{},
            .modem = EmptyRegistry{},
            .nfc = EmptyRegistry{},
            .wifi_sta = EmptyRegistry{},
            .wifi_ap = EmptyRegistry{},
            .flow = EmptyRegistry{},
            .overlay = EmptyRegistry{},
            .router = EmptyRegistry{},
            .selection = EmptyRegistry{},
        };

        allocator: Allocator,

        pub fn init(init_config: InitConfig) !@This() {
            return .{
                .allocator = init_config.allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.* = undefined;
        }

        pub fn start(self: *@This(), start_config: StartConfig) !void {
            _ = self;
            _ = start_config;
        }

        pub fn stop(self: *@This()) !void {
            _ = self;
        }

        pub fn press_single_button(self: *@This(), label: PeriphLabel) !void {
            _ = self;
            _ = label;
            return error.InvalidPeriphKind;
        }

        pub fn release_single_button(self: *@This(), label: PeriphLabel) !void {
            _ = self;
            _ = label;
            return error.InvalidPeriphKind;
        }
    };
}
