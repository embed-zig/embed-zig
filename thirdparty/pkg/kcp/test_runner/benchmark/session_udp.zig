const glib = @import("glib");
const kcp = @import("../../../kcp.zig");
const memory = @import("ikcp_memory.zig");
const Protocol = @import("../../PerfProtocol.zig");

pub const Result = struct {
    elapsed_ns: u64,
    client: Protocol.Result,
    server: Protocol.Result,
    client_snapshot: Snapshot,
    server_snapshot: Snapshot,

    pub fn mbps(self: Result) f64 {
        if (self.client.elapsed_ns == 0) return 0;
        return (@as(f64, @floatFromInt(self.client.sent_bytes)) * 8.0 * 1000.0) /
            @as(f64, @floatFromInt(self.client.elapsed_ns));
    }
};

pub const Snapshot = struct {
    output_packets: u64,
    input_packets: u64,
    output_drops: u64,
    input_errors: u64,
    xmit: u32,
    max_output_burst: u32,
    loop_work_max_us: u64,
    loop_update_max_us: u64,
    loop_late_max_us: u64,
    loop_update_max_output_burst: u32,
    loop_update_max_output_write_max_us: u64,
    loop_update_max_internal_us: u64,
};

pub fn Runner(comptime grt: type) type {
    const std = grt.std;
    const Net = grt.net;
    const PerfEndpoint = kcp.PerfEndpoint.make(grt);
    const task_options: glib.task.Options = .{ .min_stack_size = 128 * 1024 };

    return struct {
        pub fn runLocalhostUp(allocator: std.mem.Allocator, config: memory.Config) !Result {
            const request = requestFromConfig(config);
            const loopback = Net.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 0);

            var client_pc = try Net.listenPacket(.{ .allocator = allocator, .address = loopback });
            errdefer client_pc.deinit();
            var server_pc = try Net.listenPacket(.{ .allocator = allocator, .address = loopback });
            errdefer server_pc.deinit();

            const client_addr = try (try client_pc.as(Net.UdpConn)).localAddr();
            const server_addr = try (try server_pc.as(Net.UdpConn)).localAddr();

            var client_ep: PerfEndpoint = undefined;
            try client_ep.init(allocator, client_pc, server_addr, request.conv, request, .stream);
            defer client_ep.deinit();

            var server_ep: PerfEndpoint = undefined;
            try server_ep.init(allocator, server_pc, client_addr, request.conv, request, .stream);
            defer server_ep.deinit();

            var client_task = EndpointTask{
                .endpoint = &client_ep,
                .role = .client,
                .request = request,
            };
            var server_task = EndpointTask{
                .endpoint = &server_ep,
                .role = .server,
                .request = request,
            };

            const started = grt.time.instant.now();
            const client_handle = try grt.task.go("kcp/session/local-client", task_options, glib.task.Routine.init(&client_task, EndpointTask.run));
            const server_handle = try grt.task.go("kcp/session/local-server", task_options, glib.task.Routine.init(&server_task, EndpointTask.run));
            client_handle.join();
            server_handle.join();

            if (client_task.err) |err| return err;
            if (server_task.err) |err| return err;

            return .{
                .elapsed_ns = elapsedSince(started),
                .client = client_task.result,
                .server = server_task.result,
                .client_snapshot = snapshot(client_ep.session.snapshot()),
                .server_snapshot = snapshot(server_ep.session.snapshot()),
            };
        }

        const EndpointTask = struct {
            endpoint: *PerfEndpoint,
            role: kcp.PerfEndpoint.Role,
            request: Protocol.Request,
            result: Protocol.Result = .{},
            err: ?anyerror = null,

            fn run(self: *@This()) void {
                self.result = self.endpoint.run(self.role, self.request, null) catch |err| {
                    self.err = err;
                    self.endpoint.session.close();
                    return;
                };
            }
        };

        fn requestFromConfig(config: memory.Config) Protocol.Request {
            _ = config.udp_payload;
            return .{
                .protocol = .ikcp_stream,
                .direction = .up,
                .bytes = config.bytes,
                .kcp = .{
                    .send_window = config.send_window,
                    .recv_window = config.recv_window,
                    .nodelay = config.nodelay,
                    .interval_ms = @intCast(config.interval_ms),
                    .resend = config.resend,
                    .no_congestion_control = config.no_congestion_control,
                },
            };
        }

        fn snapshot(s: kcp.Session.make(grt).Snapshot) Snapshot {
            return .{
                .output_packets = s.output_packets,
                .input_packets = s.input_packets,
                .output_drops = s.output_drops,
                .input_errors = s.input_errors,
                .xmit = s.xmit,
                .max_output_burst = s.max_output_burst,
                .loop_work_max_us = s.loop_work_max_us,
                .loop_update_max_us = s.loop_update_max_us,
                .loop_late_max_us = s.loop_late_max_us,
                .loop_update_max_output_burst = s.loop_update_max_output_burst,
                .loop_update_max_output_write_max_us = s.loop_update_max_output_write_max_us,
                .loop_update_max_internal_us = s.loop_update_max_internal_us,
            };
        }

        fn elapsedSince(started: glib.time.instant.Time) u64 {
            const elapsed = grt.time.instant.since(started);
            if (elapsed <= 0) return 0;
            return @intCast(elapsed);
        }
    };
}
