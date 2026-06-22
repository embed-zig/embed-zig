const embed = @import("embed");
const glib = @import("glib");
const launcher = @import("launcher");

const net = embed.net;

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

    pub fn netManager() MockNetManager {
        return .{};
    }
};

pub fn make(comptime platform_ctx: type, comptime platform_grt: type) type {
    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = MinimalZuxApp(platform_grt);

        pub const title = "net-smoke";
        pub const description = "Runtime-bound embed.net route control smoke test.";

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
                t.logErrorf("net smoke failed: {s}", .{@errorName(err)});
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

    var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_net_smoke);
    defer t.deinit();

    t.run("net-smoke/interfaces-and-default-route", testRunner(platform_ctx, platform_grt));
    if (!t.wait()) return error.TestFailed;
}

fn runSmoke(comptime platform_ctx: type, comptime platform_grt: type) !void {
    const log = platform_grt.std.log.scoped(.zux_net_smoke);

    if (@hasDecl(platform_grt.net.Runtime, "init")) {
        try platform_grt.net.Runtime.init();
    }

    var manager_impl = platform_ctx.netManager();
    const manager = manager_impl.interfaceManager();

    var interfaces_buf: [8]net.iface.Info = undefined;
    const interfaces = try manager.listInterfaces(&interfaces_buf);
    log.info("net smoke interfaces={d}", .{interfaces.len});

    for (interfaces) |info| {
        logInterface(platform_grt, info);
    }

    const default_route = try manager.getDefaultRoute(.ipv4);
    if (default_route) |route| {
        log.info("net smoke default route interface_id={d} metric={d}", .{ route.interface_id, route.metric });
        try manager.setDefaultRoute(route);
        const updated = (try manager.getDefaultRoute(.ipv4)) orelse return error.DefaultRouteLost;
        if (updated.interface_id != route.interface_id) return error.DefaultRouteChanged;
        log.info("net smoke set default route passed interface_id={d}", .{updated.interface_id});
    } else {
        log.info("net smoke default route none", .{});
    }

    log.info("net smoke passed", .{});
}

fn logInterface(comptime platform_grt: type, info: net.iface.Info) void {
    const log = platform_grt.std.log.scoped(.zux_net_smoke);
    log.info(
        "netif id={d} name={s} up={} running={} default={} addresses={d}",
        .{
            info.id,
            info.name(),
            info.flags.up,
            info.flags.running,
            info.flags.default,
            info.addresses().len,
        },
    );

    for (info.addresses()) |address| {
        if (address.address.as4()) |ipv4| {
            log.info(
                "netif id={d} ipv4={d}.{d}.{d}.{d}/{d}",
                .{ info.id, ipv4[0], ipv4[1], ipv4[2], ipv4[3], address.prefix_len },
            );
        } else {
            log.info("netif id={d} address family={s}/{d}", .{ info.id, @tagName(address.family), address.prefix_len });
        }
    }
}

const MockNetManager = struct {
    default_route: ?net.route.Default = .{
        .family = .ipv4,
        .interface_id = 1,
        .gateway = glib.net.netip.Addr.from4(.{ 192, 168, 1, 1 }),
        .metric = 10,
    },

    pub fn interfaceManager(self: *MockNetManager) net.Manager {
        return net.Manager.init(self);
    }

    pub fn listInterfaces(_: *MockNetManager, out: []net.iface.Info) net.Error![]net.iface.Info {
        if (out.len < 1) return error.BufferTooSmall;
        out[0] = net.iface.Info.init(1, "wifi0");
        out[0].flags.up = true;
        out[0].flags.running = true;
        out[0].flags.default = true;
        try out[0].appendAddress(.{
            .family = .ipv4,
            .address = glib.net.netip.Addr.from4(.{ 192, 168, 1, 20 }),
            .prefix_len = 24,
        });
        return out[0..1];
    }

    pub fn getDefaultRoute(self: *MockNetManager, family: net.AddressFamily) net.Error!?net.route.Default {
        if (self.default_route) |route| {
            if (route.family == family) return route;
        }
        return null;
    }

    pub fn setDefaultRoute(self: *MockNetManager, default_route: net.route.Default) net.Error!void {
        self.default_route = default_route;
    }
};
