const embed = @import("embed");
const glib = @import("glib");
const launcher = @import("launcher");

const SwitchPeriph = struct {
    label: @Type(.enum_literal),
    id: u32,
    metadata: embed.zux.Metadata = .{},
};

fn Registry(comptime T: type, comptime items: anytype) type {
    return struct {
        periphs: [items.len]T = items,
        len: usize = items.len,
    };
}

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
            capacity: usize = 8,
            tick_interval: platform_grt.time.duration.Duration = 10 * platform_grt.time.duration.MilliSecond,
            task_options: glib.task.Options = .{ .min_stack_size = 8 * 1024 },
        };
        pub const PollerConfig = struct {
            poll_interval: platform_grt.time.duration.Duration = 10 * platform_grt.time.duration.MilliSecond,
            task_options: glib.task.Options = .{ .min_stack_size = 4 * 1024 },
        };
        pub const PeriphLabel = enum {
            relay,
        };
        pub const InitConfig = struct {
            allocator: platform_grt.std.mem.Allocator,
            pipeline_config: PipelineConfig = .{},
            poller_config: PollerConfig = .{},
            relay: embed.drivers.Switch,
        };
        pub const StartConfig = struct {};
        pub const registries = .{
            .adc_button = EmptyRegistry(EmptyPeriph){},
            .audio_system = EmptyRegistry(EmptyPeriph){},
            .bt = EmptyRegistry(EmptyPeriph){},
            .display = EmptyRegistry(EmptyPeriph){},
            .single_button = EmptyRegistry(EmptyPeriph){},
            .imu = EmptyRegistry(EmptyPeriph){},
            .ledstrip = EmptyRegistry(EmptyPeriph){},
            .modem = EmptyRegistry(EmptyPeriph){},
            .nfc = EmptyRegistry(EmptyPeriph){},
            .switch_output = Registry(SwitchPeriph, [_]SwitchPeriph{.{
                .label = .relay,
                .id = 1,
                .metadata = .{ .label_text = "Relay" },
            }}){},
            .pwm = EmptyRegistry(EmptyPeriph){},
            .touch = EmptyRegistry(EmptyPeriph){},
            .wifi_sta = EmptyRegistry(EmptyPeriph){},
            .wifi_ap = EmptyRegistry(EmptyPeriph){},
        };

        allocator: platform_grt.std.mem.Allocator,
        relay: embed.drivers.Switch,
        started: bool = false,

        pub fn init(config: InitConfig) !Self {
            return .{
                .allocator = config.allocator,
                .relay = config.relay,
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn start(self: *Self, config: StartConfig) !void {
            _ = config;
            try self.set_switch(.relay, true);
            self.started = true;
        }

        pub fn stop(self: *Self) !void {
            try self.set_switch(.relay, false);
            self.started = false;
        }

        pub fn set_switch(self: *Self, label: PeriphLabel, enabled: bool) !void {
            switch (label) {
                .relay => try self.relay.set(enabled),
            }
        }
    };
}

pub fn make(comptime platform_ctx: type, comptime platform_grt: type) type {
    _ = platform_ctx;
    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = MinimalZuxApp(platform_grt);

        pub const title = "switch-output-smoke";
        pub const description = "Runtime-bound switch output smoke test.";

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
            return self;
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            self.zux_app.deinit();
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn createTestRunner() glib.testing.TestRunner {
            return testRunner(platform_grt);
        }
    });
}

pub fn testRunner(comptime platform_grt: type) glib.testing.TestRunner {
    const ZuxApp = MinimalZuxApp(platform_grt);

    const Runner = struct {
        pub fn init(self: *@This(), allocator: platform_grt.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: platform_grt.std.mem.Allocator) bool {
            _ = self;

            var relay = TestSwitch{};
            var app = ZuxApp.init(.{
                .allocator = allocator,
                .relay = relay.handle(),
            }) catch |err| {
                t.logErrorf("init failed: {s}", .{@errorName(err)});
                return false;
            };
            defer app.deinit();

            app.start(.{}) catch |err| {
                t.logErrorf("start failed: {s}", .{@errorName(err)});
                return false;
            };
            if (!relay.enabled) {
                t.logError("start did not enable relay");
                return false;
            }

            app.set_switch(.relay, false) catch |err| {
                t.logErrorf("set_switch(false) failed: {s}", .{@errorName(err)});
                return false;
            };
            if (relay.enabled) {
                t.logError("set_switch(false) did not disable relay");
                return false;
            }

            app.stop() catch |err| {
                t.logErrorf("stop failed: {s}", .{@errorName(err)});
                return false;
            };
            if (relay.enabled) {
                t.logError("stop did not leave relay disabled");
                return false;
            }
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

    var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_switch_output_smoke);
    defer t.deinit();

    t.run("switch-output-smoke/relay", testRunner(platform_grt));
    if (!t.wait()) return error.TestFailed;
}

const TestSwitch = struct {
    enabled: bool = false,

    pub fn handle(self: *@This()) embed.drivers.Switch {
        return embed.drivers.Switch.init(self);
    }

    pub fn set(self: *@This(), enabled: bool) embed.drivers.Switch.Error!void {
        self.enabled = enabled;
    }

    pub fn get(self: *@This()) embed.drivers.Switch.Error!bool {
        return self.enabled;
    }
};
