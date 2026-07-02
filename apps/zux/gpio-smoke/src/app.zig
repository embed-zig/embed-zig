const embed = @import("embed");
const glib = @import("glib");
const launcher = @import("launcher");

const GpioPeriph = struct {
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
    const Gpio = embed.drivers.Gpio;
    const EventHook = embed.zux.component.gpio.EventHook;
    const Message = embed.zux.pipeline.Message;
    const Emitter = embed.zux.pipeline.Emitter;
    const log = platform_grt.std.log.scoped(.zux_gpio_smoke);

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
            smoke,
        };
        pub const InitConfig = struct {
            allocator: platform_grt.std.mem.Allocator,
            pipeline_config: PipelineConfig = .{},
            poller_config: PollerConfig = .{},
            smoke: Gpio,
            enable_toggle_task: bool = true,
        };
        pub const StartConfig = struct {};
        pub const registries = .{
            .adc_button = EmptyRegistry(EmptyPeriph){},
            .audio_system = EmptyRegistry(EmptyPeriph){},
            .bt = EmptyRegistry(EmptyPeriph){},
            .display = EmptyRegistry(EmptyPeriph){},
            .single_button = EmptyRegistry(EmptyPeriph){},
            .gpio = Registry(GpioPeriph, [_]GpioPeriph{
                .{
                    .label = .smoke,
                    .id = 26,
                    .metadata = .{ .label_text = "GPIO smoke" },
                },
            }){},
            .imu = EmptyRegistry(EmptyPeriph){},
            .ledstrip = EmptyRegistry(EmptyPeriph){},
            .modem = EmptyRegistry(EmptyPeriph){},
            .nfc = EmptyRegistry(EmptyPeriph){},
            .pwm = EmptyRegistry(EmptyPeriph){},
            .switch_output = EmptyRegistry(EmptyPeriph){},
            .touch = EmptyRegistry(EmptyPeriph){},
            .wifi_sta = EmptyRegistry(EmptyPeriph){},
            .wifi_ap = EmptyRegistry(EmptyPeriph){},
        };

        const Sink = struct {
            count: usize = 0,
            last_event: ?embed.zux.component.gpio.event.RawChanged = null,

            pub fn emit(self: *@This(), message: Message) !void {
                switch (message.body) {
                    .raw_gpio_changed => |event| {
                        self.count += 1;
                        self.last_event = event;
                        log.info("zux raw_gpio_changed source={} edge={s} level={s} count={}", .{
                            event.source_id,
                            @tagName(event.edge),
                            @tagName(event.level),
                            self.count,
                        });
                    },
                    else => {},
                }
            }
        };

        allocator: platform_grt.std.mem.Allocator,
        smoke: Gpio,
        hook: EventHook = EventHook.init(26),
        sink: Sink = .{},
        enable_toggle_task: bool,
        task_started: bool = false,

        pub fn init(config: InitConfig) !Self {
            return .{
                .allocator = config.allocator,
                .smoke = config.smoke,
                .enable_toggle_task = config.enable_toggle_task,
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn start(self: *Self, config: StartConfig) !void {
            _ = config;
            try self.smoke.setDirection(.output);
            try self.smoke.write(.low);
            self.hook.bindOutput(Emitter.init(&self.sink));
            try self.hook.attach(self.smoke);

            if (self.enable_toggle_task and !self.task_started) {
                const task = try platform_grt.task.go("zux/gpio-smoke/toggle", .{
                    .min_stack_size = 4096,
                }, platform_grt.task.Routine.init(self, toggleTask));
                task.detach();
                self.task_started = true;
            }
            log.info("zux gpio smoke started gpio=smoke pin=26", .{});
        }

        pub fn stop(self: *Self) !void {
            self.hook.detach(self.smoke);
            self.hook.clearOutput();
        }

        pub fn gpio_changed(self: *Self, label: PeriphLabel, edge: Gpio.Edge, level: Gpio.Level) !void {
            switch (label) {
                .smoke => try self.sink.emit(.{
                    .body = .{
                        .raw_gpio_changed = .{
                            .source_id = 26,
                            .edge = edge,
                            .level = level,
                        },
                    },
                }),
            }
        }

        fn toggleTask(self: *Self) void {
            var high = false;
            while (true) {
                high = !high;
                const target: Gpio.Level = if (high) .high else .low;
                self.smoke.write(target) catch |err| {
                    log.err("zux gpio smoke write failed: {}", .{err});
                    continue;
                };
                log.info("zux gpio smoke output target={s}", .{@tagName(target)});
                platform_grt.time.sleepNanos(@intCast(500 * platform_grt.time.duration.MilliSecond));
            }
        }
    };
}

pub fn make(comptime platform_ctx: type, comptime platform_grt: type) type {
    _ = platform_ctx;
    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = MinimalZuxApp(platform_grt);

        pub const title = "gpio-smoke";
        pub const description = "Runtime-bound GPIO IRQ smoke test.";

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

            var pin = TestGpio{};
            var app = ZuxApp.init(.{
                .allocator = allocator,
                .smoke = pin.handle(),
                .enable_toggle_task = false,
            }) catch |err| {
                t.logErrorf("init failed: {s}", .{@errorName(err)});
                return false;
            };
            defer app.deinit();

            app.start(.{}) catch |err| {
                t.logErrorf("start failed: {s}", .{@errorName(err)});
                return false;
            };

            pin.write(.high) catch |err| {
                t.logErrorf("write high failed: {s}", .{@errorName(err)});
                return false;
            };
            if (app.sink.count != 1 or app.sink.last_event == null or app.sink.last_event.?.edge != .rising) {
                t.logError("rising edge was not emitted");
                return false;
            }

            pin.write(.low) catch |err| {
                t.logErrorf("write low failed: {s}", .{@errorName(err)});
                return false;
            };
            if (app.sink.count != 2 or app.sink.last_event == null or app.sink.last_event.?.edge != .falling) {
                t.logError("falling edge was not emitted");
                return false;
            }

            app.stop() catch |err| {
                t.logErrorf("stop failed: {s}", .{@errorName(err)});
                return false;
            };
            pin.write(.high) catch |err| {
                t.logErrorf("write after stop failed: {s}", .{@errorName(err)});
                return false;
            };
            if (app.sink.count != 2) {
                t.logError("stop did not detach gpio event hook");
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

    var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_gpio_smoke);
    defer t.deinit();

    t.run("gpio-smoke/event-hook", testRunner(platform_grt));
    if (!t.wait()) return error.TestFailed;
}

const TestGpio = struct {
    level: embed.drivers.Gpio.Level = .low,
    interrupt_edge: ?embed.drivers.Gpio.Edge = null,
    callback_ctx: ?*const anyopaque = null,
    callback_fn: ?embed.drivers.Gpio.CallbackFn = null,

    fn handle(self: *@This()) embed.drivers.Gpio {
        return embed.drivers.Gpio.init(self);
    }

    pub fn read(self: *@This()) embed.drivers.Gpio.Error!embed.drivers.Gpio.Level {
        return self.level;
    }

    pub fn write(self: *@This(), level: embed.drivers.Gpio.Level) embed.drivers.Gpio.Error!void {
        const previous = self.level;
        self.level = level;
        const edge = edgeFromTransition(previous, level);
        if (shouldEmit(self.interrupt_edge, previous, level, edge)) {
            if (self.callback_ctx) |ctx| {
                if (self.callback_fn) |func| func(ctx, .{
                    .edge = edge,
                    .level = level,
                });
            }
        }
    }

    pub fn setDirection(self: *@This(), direction: embed.drivers.Gpio.Direction) embed.drivers.Gpio.Error!void {
        _ = self;
        _ = direction;
    }

    pub fn configureInterrupt(self: *@This(), edge: embed.drivers.Gpio.Edge) embed.drivers.Gpio.Error!void {
        self.interrupt_edge = edge;
    }

    pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: embed.drivers.Gpio.CallbackFn) void {
        self.callback_ctx = ctx;
        self.callback_fn = emit_fn;
    }

    pub fn clearEventCallback(self: *@This()) void {
        self.callback_ctx = null;
        self.callback_fn = null;
    }
};

fn edgeFromTransition(previous: embed.drivers.Gpio.Level, current: embed.drivers.Gpio.Level) embed.drivers.Gpio.Edge {
    if (previous == .low and current == .high) return .rising;
    if (previous == .high and current == .low) return .falling;
    return switch (current) {
        .low => .low_level,
        .high => .high_level,
    };
}

fn shouldEmit(
    configured: ?embed.drivers.Gpio.Edge,
    previous: embed.drivers.Gpio.Level,
    current: embed.drivers.Gpio.Level,
    edge: embed.drivers.Gpio.Edge,
) bool {
    const target = configured orelse return false;
    return switch (target) {
        .rising => previous == .low and current == .high,
        .falling => previous == .high and current == .low,
        .both => previous != current,
        .low_level => current == .low,
        .high_level => current == .high,
    } and switch (edge) {
        .rising, .falling, .low_level, .high_level => true,
        .both => false,
    };
}
