const embed = @import("embed");
const glib = @import("glib");
const app_config = @import("command_console_config");
const launcher = @import("launcher");

const cmd = embed.cmd;

const bt_service_uuid: u16 = 0xFEE0;
const bt_tx_char_uuid: u16 = 0xFEE1;
const bt_rx_char_uuid: u16 = 0xFEE2;

const BtPeriph = struct {
    label: @Type(.enum_literal),
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
            bt: ?embed.bt.Host = null,
        };
        pub const StartConfig = struct {};
        pub const registries = .{
            .adc_button = EmptyRegistry(EmptyPeriph){},
            .bt = Registry(BtPeriph, [_]BtPeriph{.{
                .label = .bt,
                .metadata = .{ .label_text = "Bluetooth" },
            }}){},
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
        bt: ?embed.bt.Host,
        started: bool = false,

        pub fn init(config: InitConfig) !Self {
            return .{
                .allocator = config.allocator,
                .bt = config.bt,
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

pub const CommandRuntime = struct {
    registry: cmd.Executor.Registry,

    const Self = @This();

    pub fn init(allocator: glib.std.mem.Allocator) Self {
        return .{
            .registry = cmd.Executor.Registry.init(allocator),
        };
    }

    pub fn registerMinimal(self: *Self, options: cmd.common.Options) !void {
        try cmd.common.registerMinimal(&self.registry, options);
    }

    pub fn deinit(self: *Self) void {
        self.registry.deinit();
    }

    pub fn executor(self: *Self) cmd.Executor {
        return self.registry.executor();
    }

    pub fn executeLine(self: *Self, line: []const u8, out: cmd.Output) !void {
        try cmd.uart.executeLine(self.executor(), line, out);
    }
};

pub fn make(comptime platform_ctx: type, comptime platform_grt: type) type {
    const log = platform_grt.std.log.scoped(.zux_command_console);
    const Bt = embed.bt.make(platform_grt);
    const BtKcp = if (app_config.enable_bt_kcp)
        embed.bt.kcp.make(platform_grt, @import("kcp"))
    else
        void;
    const BtServer = Bt.Server;
    const BtStream = if (app_config.enable_bt_kcp) BtKcp.Stream else void;

    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = MinimalZuxApp(platform_grt);

        pub const title = "command-console";
        pub const description = "Command console over UART, BT/KCP, and desktop TCP.";

        allocator: glib.std.mem.Allocator,
        zux_app: ZuxApp,
        commands: CommandRuntime,
        bt_server: ?BtServer = null,
        bt_endpoint: if (app_config.enable_bt_kcp) ?BtKcp.server.Endpoint else void =
            if (app_config.enable_bt_kcp) null else {},
        bt_task: ?platform_grt.task.Handle = null,

        pub fn init(allocator: glib.std.mem.Allocator, base_config: ZuxApp.InitConfig) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            var init_config = base_config;
            init_config.allocator = allocator;
            self.* = .{
                .allocator = allocator,
                .zux_app = try ZuxApp.init(init_config),
                .commands = CommandRuntime.init(allocator),
            };
            errdefer self.zux_app.deinit();
            errdefer self.commands.deinit();
            try self.commands.registerMinimal(.{ .version = "command-console" });

            try runSmoke(platform_ctx, platform_grt, allocator);
            return self;
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            self.stopBtKcp();
            self.commands.deinit();
            self.zux_app.deinit();
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn start(self: *Self) !void {
            if (@hasDecl(platform_ctx, "attachCommandConsole")) {
                try platform_ctx.attachCommandConsole(self.commands.executor());
            }
            try self.startBtKcp();
            try self.zux_app.start(.{});
        }

        pub fn stop(self: *Self) void {
            self.stopBtKcp();
            self.zux_app.stop() catch {};
        }

        pub fn createTestRunner() glib.testing.TestRunner {
            return testRunner(platform_ctx, platform_grt);
        }

        fn startBtKcp(self: *Self) !void {
            if (comptime !app_config.enable_bt_kcp) return;
            const host = self.zux_app.bt orelse return;
            if (self.bt_task != null) return;

            self.bt_server = try BtServer.init(self.allocator);
            errdefer {
                self.bt_server.?.deinit();
                self.bt_server = null;
            }

            var server = &self.bt_server.?;
            server.bind(host.peripheral());
            server.setConfig(.{ .services = &bt_services });

            self.bt_endpoint = try BtKcp.server.Endpoint.init(self.allocator, .{
                .service_uuid = bt_service_uuid,
                .tx_char_uuid = bt_tx_char_uuid,
                .rx_char_uuid = bt_rx_char_uuid,
                .handler = .{ .onStream = onBtStream },
                .ctx = self,
                .task_options = .{ .min_stack_size = 6 * 1024 },
            });
            errdefer {
                self.bt_endpoint.?.deinit();
                self.bt_endpoint = null;
            }

            try self.bt_endpoint.?.handle(server);
            try server.start();
            errdefer server.stop();
            try server.startAdvertising(.{
                .device_name = "cmd-console",
                .service_uuids = &.{bt_service_uuid},
            });
            self.bt_task = try platform_grt.task.go(
                "zux/cmd/bt-kcp",
                .{ .min_stack_size = 8 * 1024 },
                glib.task.Routine.init(self, runBtEndpoint),
            );
        }

        fn stopBtKcp(self: *Self) void {
            if (comptime !app_config.enable_bt_kcp) return;
            if (self.bt_endpoint) |*endpoint| {
                endpoint.close();
            }
            if (self.bt_task) |task| {
                task.join();
                self.bt_task = null;
            }
            if (self.bt_endpoint) |*endpoint| {
                endpoint.deinit();
                self.bt_endpoint = null;
            }
            if (self.bt_server) |*server| {
                server.stop();
                server.deinit();
                self.bt_server = null;
            }
        }

        fn runBtEndpoint(self: *Self) void {
            if (comptime !app_config.enable_bt_kcp) return;
            const endpoint = &(self.bt_endpoint orelse return);
            endpoint.run() catch |err| {
                log.err("bt command endpoint stopped: {s}", .{@errorName(err)});
            };
        }

        fn onBtStream(ctx: ?*anyopaque, stream: *BtStream) anyerror!void {
            if (comptime !app_config.enable_bt_kcp) return;
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            defer stream.deinit();

            var read_buf: [256]u8 = undefined;
            var line_buf: [1024]u8 = undefined;
            var line_len: usize = 0;
            while (true) {
                const n = stream.read(&read_buf) catch |err| switch (@as(anyerror, err)) {
                    error.Closed => return,
                    else => return err,
                };
                for (read_buf[0..n]) |byte| {
                    if (byte == '\r') continue;
                    if (byte == '\n') {
                        try executeBtLine(self, stream, line_buf[0..line_len]);
                        line_len = 0;
                        continue;
                    }
                    if (line_len == line_buf.len) return error.CommandLineTooLong;
                    line_buf[line_len] = byte;
                    line_len += 1;
                }
            }
        }

        fn executeBtLine(self: *Self, stream: *BtStream, line: []const u8) !void {
            if (comptime !app_config.enable_bt_kcp) return;
            if (line.len == 0) return;
            try cmd.bt_kcp.executeLine(BtStream, self.commands.executor(), stream, line);
        }

        const bt_chars = [_]embed.bt.Peripheral.CharDef{
            embed.bt.Peripheral.Char(bt_tx_char_uuid, .{ .notify = true }),
            embed.bt.Peripheral.Char(bt_rx_char_uuid, .{ .write = true, .write_without_response = true }),
        };
        const bt_services = [_]embed.bt.Peripheral.ServiceDef{
            embed.bt.Peripheral.Service(bt_service_uuid, &bt_chars),
        };
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
                t.logErrorf("command console smoke failed: {s}", .{@errorName(err)});
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

    var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_command_console);
    defer t.deinit();

    t.run("command-console", testRunner(platform_ctx, platform_grt));
    if (!t.wait()) return error.TestFailed;
}

fn runSmoke(comptime platform_ctx: type, comptime platform_grt: type, allocator: glib.std.mem.Allocator) !void {
    _ = platform_ctx;
    _ = platform_grt;

    var runtime = CommandRuntime.init(allocator);
    defer runtime.deinit();
    try runtime.registerMinimal(.{ .version = "command-console" });

    var buffer = BufferOutput{};
    const out = cmd.Output.make(BufferOutput).init(&buffer);

    try runtime.executeLine("ping", out);
    if (!glib.std.mem.eql(u8, "pong\n", buffer.bytes())) return error.CommandSmokeMismatch;

    buffer.clear();
    try runtime.executeLine("version", out);
    if (!glib.std.mem.eql(u8, "command-console\n", buffer.bytes())) return error.CommandSmokeMismatch;

    if (!glib.std.mem.eql(u8, "127.0.0.1", cmd.desktop_tcp.default_addr)) return error.CommandSmokeMismatch;
    if (cmd.desktop_tcp.default_port != 39074) return error.CommandSmokeMismatch;
}

const BufferOutput = struct {
    data: [512]u8 = undefined,
    len: usize = 0,

    pub fn write(self: *BufferOutput, chunk: []const u8) !usize {
        if (self.len + chunk.len > self.data.len) return error.BufferTooSmall;
        @memcpy(self.data[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
        return chunk.len;
    }

    pub fn bytes(self: *const BufferOutput) []const u8 {
        return self.data[0..self.len];
    }

    pub fn clear(self: *BufferOutput) void {
        self.len = 0;
    }
};
