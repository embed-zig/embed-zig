const embed = @import("embed");
const glib = @import("glib");
const kcp = @import("kcp");
const launcher = @import("launcher");
const config = @import("netperf_app_config");

fn EmptyRegistry(comptime T: type) type {
    return struct {
        periphs: [0]T = .{},
        len: usize = 0,
    };
}

const EmptyPeriph = struct {
    label: @Type(.enum_literal) = .none,
};

const WifiStaRegistry = struct {
    const Periph = struct {
        label: @Type(.enum_literal),
        id: u32,
        control_type: type,
    };

    periphs: [1]Periph = .{
        .{ .label = .wifi, .id = 1, .control_type = embed.drivers.wifi.Sta },
    },
    len: usize = 1,
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
            wifi: embed.drivers.wifi.Sta = undefined,
            pipeline_config: PipelineConfig = .{},
            poller_config: PollerConfig = .{},
        };
        pub const StartConfig = struct {};
        pub const PeriphLabel = enum { none };
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
            .wifi_sta = WifiStaRegistry{},
            .wifi_ap = EmptyRegistry(EmptyPeriph){},
        };

        allocator: platform_grt.std.mem.Allocator,
        wifi: embed.drivers.wifi.Sta,
        started: bool = false,

        pub fn init(init_config: InitConfig) !Self {
            return .{
                .allocator = init_config.allocator,
                .wifi = init_config.wifi,
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn start(self: *Self, start_config: StartConfig) !void {
            _ = start_config;
            self.started = true;
            try startNetperfTask(platform_grt, self.allocator, self.wifi);
        }

        pub fn stop(self: *Self) !void {
            self.started = false;
        }

        pub fn press_single_button(self: *Self, label: PeriphLabel) !void {
            _ = self;
            _ = label;
            return error.InvalidPeriphKind;
        }

        pub fn release_single_button(self: *Self, label: PeriphLabel) !void {
            _ = self;
            _ = label;
            return error.InvalidPeriphKind;
        }

        pub fn press_grouped_button(self: *Self, label: PeriphLabel, button_id: u32) !void {
            _ = self;
            _ = label;
            _ = button_id;
            return error.InvalidPeriphKind;
        }

        pub fn release_grouped_button(self: *Self, label: PeriphLabel) !void {
            _ = self;
            _ = label;
            return error.InvalidPeriphKind;
        }
    };
}

pub fn make(comptime platform_ctx: type, comptime platform_grt: type) type {
    _ = platform_ctx;
    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = MinimalZuxApp(platform_grt);

        pub const title = "netperf";
        pub const description = "TCP, UDP, and KCP over UDP baseline runner.";

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

fn startNetperfTask(
    comptime platform_grt: type,
    allocator: platform_grt.std.mem.Allocator,
    wifi: embed.drivers.wifi.Sta,
) !void {
    const NetperfTask = struct {
        allocator: platform_grt.std.mem.Allocator,
        wifi: embed.drivers.wifi.Sta,

        fn run(self: *@This()) void {
            const task_allocator = self.allocator;
            defer task_allocator.destroy(self);

            const log = platform_grt.std.log.scoped(.zux_netperf);
            ensureWifiReady(platform_grt, self.wifi) catch |err| {
                log.err("netperf wifi failed: {s}", .{@errorName(err)});
                return;
            };
            runNetperf(platform_grt, task_allocator) catch |err| {
                log.err("netperf failed: {s}", .{@errorName(err)});
                return;
            };
        }
    };

    const task_ctx = try allocator.create(NetperfTask);
    errdefer allocator.destroy(task_ctx);
    task_ctx.* = .{
        .allocator = allocator,
        .wifi = wifi,
    };

    const handle = try platform_grt.task.go(
        "netperf/run",
        .{ .min_stack_size = 96 * 1024 },
        glib.task.Routine.init(task_ctx, NetperfTask.run),
    );
    handle.detach();
}

pub fn testRunner(comptime platform_grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: platform_grt.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: platform_grt.std.mem.Allocator) bool {
            _ = self;

            runNetperf(platform_grt, allocator) catch |err| {
                t.logErrorf("netperf failed: {s}", .{@errorName(err)});
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

const Protocol = kcp.PerfProtocol;
const max_cpu_tasks = 128;
const max_cpu_top_tasks = 8;

const CpuEntry = struct {
    name: [16]u8 = [_]u8{0} ** 16,
    runtime: u64 = 0,
};

const CpuSample = struct {
    supported: bool = false,
    entries: [max_cpu_tasks]CpuEntry = [_]CpuEntry{.{}} ** max_cpu_tasks,
    len: usize = 0,
};

fn runNetperf(comptime platform_grt: type, allocator: platform_grt.std.mem.Allocator) !void {
    if (glib.std.mem.eql(u8, config.protocol, "all")) {
        try runNetperfProtocol(platform_grt, allocator, .tcp);
        try runNetperfProtocol(platform_grt, allocator, .udp);
        try runNetperfProtocol(platform_grt, allocator, .kcp);
        return;
    }

    try runNetperfProtocol(platform_grt, allocator, try Protocol.Protocol.parse(config.protocol));
}

fn runNetperfProtocol(
    comptime platform_grt: type,
    allocator: platform_grt.std.mem.Allocator,
    protocol: Protocol.Protocol,
) !void {
    if (glib.std.mem.eql(u8, config.direction, "all")) {
        try runNetperfOne(platform_grt, allocator, protocol, .up);
        try runNetperfOne(platform_grt, allocator, protocol, .down);
        try runNetperfOne(platform_grt, allocator, protocol, .duplex);
        if (protocol == .tcp or protocol == .kcp) {
            try runNetperfOne(platform_grt, allocator, protocol, .ping);
        }
        return;
    }

    try runNetperfOne(platform_grt, allocator, protocol, try Protocol.Direction.parse(config.direction));
}

fn ensureWifiReady(comptime platform_grt: type, wifi: embed.drivers.wifi.Sta) !void {
    if (!config.wifi_connect) return;

    const log = platform_grt.std.log.scoped(.zux_netperf);
    const poll_interval = 100 * platform_grt.time.duration.MilliSecond;
    const timeout = 30 * platform_grt.time.duration.Second;
    const retry_interval = 500 * platform_grt.time.duration.MilliSecond;

    log.info("wifi connect ssid={s}", .{config.wifi_ssid});
    wifi.setPowerSave(.none) catch |err| {
        log.warn("wifi set power save none failed: {s}", .{@errorName(err)});
    };

    var elapsed: @TypeOf(timeout) = 0;
    var next_retry: @TypeOf(timeout) = 0;
    while (elapsed < timeout) : (elapsed += poll_interval) {
        if (wifi.getIpInfo() != null) {
            log.info("wifi got ip", .{});
            return;
        }
        const state = wifi.getState();
        if (elapsed >= next_retry and state != .connecting and state != .connected) {
            wifi.connect(.{
                .ssid = config.wifi_ssid,
                .password = config.wifi_password,
                .timeout = timeout,
            }) catch |err| {
                log.warn("wifi connect attempt failed: {s}", .{@errorName(err)});
            };
            next_retry = elapsed + retry_interval;
        }
        platform_grt.time.sleep(poll_interval);
    }
    return error.WifiIpTimeout;
}

fn runNetperfOne(
    comptime platform_grt: type,
    allocator: platform_grt.std.mem.Allocator,
    protocol: Protocol.Protocol,
    direction: Protocol.Direction,
) !void {
    const log = platform_grt.std.log.scoped(.zux_netperf);
    const Client = kcp.NetperfClient(platform_grt);

    const host = try glib.net.netip.Addr.parse(config.host);
    const control_addr = glib.net.netip.AddrPort.init(host, config.port);
    const request = Protocol.Request{
        .protocol = protocol,
        .direction = direction,
        .bytes = config.bytes,
        .kcp = .{
            .send_window = config.send_window,
            .recv_window = config.recv_window,
            .nodelay = config.nodelay,
            .interval_ms = config.interval_ms,
            .resend = config.resend,
            .no_congestion_control = config.no_congestion_control,
        },
    };

    log.info(
        "netperf start protocol={s} direction={s} host={s} port={d} bytes={d} stream_chunk={d} udp_payload={d} wnd={d}/{d} nodelay={d} interval={d} resend={d} nc={d}",
        .{
            @tagName(protocol),
            @tagName(direction),
            config.host,
            config.port,
            config.bytes,
            request.streamChunk(),
            request.udpPayload(),
            config.send_window,
            config.recv_window,
            config.nodelay,
            config.interval_ms,
            config.resend,
            config.no_congestion_control,
        },
    );

    var client = Client.init(allocator);
    const cpu_before = sampleCpu(platform_grt);
    const result = try client.run(control_addr, request);
    const cpu_after = sampleCpu(platform_grt);
    log.info(
        "netperf {s}/{s} client sent={d} recv={d} elapsed_ns={d} mbps={d:.3} packets={d} errors={d} first_byte_ns={d} rtt_ns={d}",
        .{
            @tagName(protocol),
            @tagName(direction),
            result.client.sent_bytes,
            result.client.received_bytes,
            result.client.elapsed_ns,
            result.client.mbps(),
            result.client.packets,
            result.client.errors,
            result.client.first_byte_ns,
            result.client.rtt_ns,
        },
    );
    log.info(
        "netperf {s}/{s} server sent={d} recv={d} elapsed_ns={d} mbps={d:.3} packets={d} errors={d} first_byte_ns={d} rtt_ns={d}",
        .{
            @tagName(protocol),
            @tagName(direction),
            result.server.sent_bytes,
            result.server.received_bytes,
            result.server.elapsed_ns,
            result.server.mbps(),
            result.server.packets,
            result.server.errors,
            result.server.first_byte_ns,
            result.server.rtt_ns,
        },
    );
    if (direction == .up) {
        log.info(
            "netperf {s}/{s} summary mbps={d:.3} sent={d} recv={d}",
            .{
                @tagName(protocol),
                @tagName(direction),
                result.server.mbps(),
                result.client.sent_bytes,
                result.server.received_bytes,
            },
        );
    } else if (direction == .down) {
        log.info(
            "netperf {s}/{s} summary mbps={d:.3} sent={d} recv={d}",
            .{
                @tagName(protocol),
                @tagName(direction),
                result.client.mbps(),
                result.server.sent_bytes,
                result.client.received_bytes,
            },
        );
    } else if (direction == .duplex) {
        const mbps = @min(result.client.mbps(), result.server.mbps());
        log.info(
            "netperf {s}/{s} summary mbps={d:.3} sent={d} recv={d}",
            .{
                @tagName(protocol),
                @tagName(direction),
                mbps,
                result.client.sent_bytes + result.server.sent_bytes,
                result.client.received_bytes + result.server.received_bytes,
            },
        );
    } else {
        log.info(
            "netperf {s}/{s} summary first_byte_ns={d} rtt_ns={d} errors={d}",
            .{
                @tagName(protocol),
                @tagName(direction),
                result.client.first_byte_ns,
                result.client.rtt_ns,
                result.client.errors + result.server.errors,
            },
        );
    }
    logCpuDelta(platform_grt, protocol, direction, cpu_before, cpu_after);
}

fn sampleCpu(comptime platform_grt: type) CpuSample {
    var sample = CpuSample{};
    if (comptime @hasDecl(platform_grt.system, "taskRuntimeSnapshot")) {
        var entries: [max_cpu_tasks]platform_grt.system.TaskRuntimeEntry = undefined;
        const len = platform_grt.system.taskRuntimeSnapshot(entries[0..]);
        sample.supported = len > 0;
        sample.len = @min(len, max_cpu_tasks);
        for (entries[0..sample.len], 0..) |entry, i| {
            sample.entries[i] = .{
                .name = entry.name,
                .runtime = entry.runtime,
            };
        }
    }
    return sample;
}

fn logCpuDelta(
    comptime platform_grt: type,
    protocol: Protocol.Protocol,
    direction: Protocol.Direction,
    before: CpuSample,
    after: CpuSample,
) void {
    const log = platform_grt.std.log.scoped(.zux_netperf);
    if (!before.supported or !after.supported) {
        log.info("netperf {s}/{s} cpu unsupported", .{ @tagName(protocol), @tagName(direction) });
        return;
    }

    var deltas: [max_cpu_tasks]u64 = [_]u64{0} ** max_cpu_tasks;
    var total: u64 = 0;
    var idle: u64 = 0;
    for (after.entries[0..after.len], 0..) |entry, i| {
        const delta = runtimeDelta(before, entry);
        deltas[i] = delta;
        total += delta;
        if (isIdleTask(&entry.name)) idle += delta;
    }
    if (total == 0) {
        log.info("netperf {s}/{s} cpu no-delta", .{ @tagName(protocol), @tagName(direction) });
        return;
    }

    const busy = total - idle;
    log.info(
        "netperf {s}/{s} cpu busy={d:.2}% idle={d:.2}% total_runtime={d} tasks={d}",
        .{
            @tagName(protocol),
            @tagName(direction),
            percent(busy, total),
            percent(idle, total),
            total,
            after.len,
        },
    );

    var used: [max_cpu_tasks]bool = [_]bool{false} ** max_cpu_tasks;
    var printed: usize = 0;
    while (printed < max_cpu_top_tasks) : (printed += 1) {
        const index = topDeltaIndex(deltas[0..after.len], used[0..after.len]) orelse break;
        used[index] = true;
        if (deltas[index] == 0) break;
        log.info(
            "netperf {s}/{s} cpu task name={s} pct={d:.2}% runtime={d}",
            .{
                @tagName(protocol),
                @tagName(direction),
                entryName(&after.entries[index].name),
                percent(deltas[index], total),
                deltas[index],
            },
        );
    }
}

fn runtimeDelta(before: CpuSample, after: CpuEntry) u64 {
    const name = entryName(&after.name);
    for (before.entries[0..before.len]) |entry| {
        if (glib.std.mem.eql(u8, name, entryName(&entry.name))) {
            return after.runtime -| entry.runtime;
        }
    }
    return after.runtime;
}

fn topDeltaIndex(deltas: []const u64, used: []const bool) ?usize {
    var best: ?usize = null;
    var best_delta: u64 = 0;
    for (deltas, 0..) |delta, i| {
        if (used[i]) continue;
        if (best == null or delta > best_delta) {
            best = i;
            best_delta = delta;
        }
    }
    return best;
}

fn isIdleTask(name: *const [16]u8) bool {
    return glib.std.mem.startsWith(u8, entryName(name), "IDLE");
}

fn entryName(name: *const [16]u8) []const u8 {
    return glib.std.mem.sliceTo(name.*[0..], 0);
}

fn percent(value: u64, total: u64) f64 {
    if (total == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(total));
}

fn validateProtocol(value: []const u8) !void {
    if (glib.std.mem.eql(u8, value, "all")) return;
    _ = try Protocol.Protocol.parse(value);
}

fn validateDirection(value: []const u8) !void {
    if (glib.std.mem.eql(u8, value, "all")) return;
    _ = try Protocol.Direction.parse(value);
}
