const glib = @import("glib");
const client_mod = @import("../../PerfClient.zig");
const protocol = @import("../../PerfProtocol.zig");
const server_mod = @import("../../PerfServer.zig");

const server_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };

pub fn make(comptime grt: type, allocator: glib.std.mem.Allocator) glib.testing.TestRunner {
    _ = allocator;
    const Runner = struct {
        allocator: glib.std.mem.Allocator,

        pub fn init(self: *@This(), test_allocator: glib.std.mem.Allocator) !void {
            self.allocator = test_allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, test_allocator: glib.std.mem.Allocator) bool {
            _ = test_allocator;

            runKcpSmoke(grt, self.allocator, t) catch |err| {
                t.logErrorf("netperf kcp loopback failed: {s}", .{@errorName(err)});
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), test_allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = test_allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{ .allocator = undefined };
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

fn runKcpSmoke(comptime grt: type, allocator: glib.std.mem.Allocator, t: *glib.testing.T) !void {
    const bytes = 64 * 1024;
    const Server = server_mod.make(grt);
    const Client = client_mod.make(grt);
    const ServerTask = struct {
        server: *Server,
        out: *?anyerror,

        pub fn run(self: *@This()) void {
            _ = self.server.serveOnce() catch |err| {
                grt.std.log.scoped(.kcp_test_runner).err("server failed: {s}", .{@errorName(err)});
                self.out.* = err;
                return;
            };
        }
    };
    const addr = glib.net.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 19821);
    var server = Server.init(allocator, .{
        .control_addr = addr,
    });

    var server_result: ?anyerror = null;
    var server_task = ServerTask{ .server = &server, .out = &server_result };
    const thread = try grt.task.go("testing/kcp/server", server_task_options, glib.task.Routine.init(&server_task, ServerTask.run));

    grt.time.sleep(50 * glib.time.duration.MilliSecond);

    var client = Client.init(allocator);
    const result = try client.run(addr, .{
        .protocol = .kcp,
        .direction = .down,
        .bytes = bytes,
        .kcp = .{
            .send_window = 64,
            .recv_window = 64,
            .nodelay = 1,
            .interval_ms = 10,
            .resend = 2,
            .no_congestion_control = 1,
            .stream = true,
        },
    });
    thread.join();

    if (server_result) |err| return err;
    const log = grt.std.log.scoped(.kcp_test_runner);
    log.info(
        "kcp loopback down client_recv={} client_elapsed_ms={} client_mbps={d:.3} server_sent={} server_elapsed_ms={} server_mbps={d:.3}",
        .{
            result.client.received_bytes,
            elapsedMs(result.client),
            resultMbps(result.client),
            result.server.sent_bytes,
            elapsedMs(result.server),
            resultMbps(result.server),
        },
    );
    t.logInfof(
        "kcp loopback down client_recv={} client_elapsed_ms={} client_mbps={d:.3} server_sent={} server_elapsed_ms={} server_mbps={d:.3}",
        .{
            result.client.received_bytes,
            elapsedMs(result.client),
            resultMbps(result.client),
            result.server.sent_bytes,
            elapsedMs(result.server),
            resultMbps(result.server),
        },
    );
    try grt.std.testing.expectEqual(@as(usize, bytes), result.client.received_bytes);
}

fn elapsedMs(result: protocol.Result) u64 {
    return @divTrunc(result.elapsed_ns, glib.time.duration.MilliSecond);
}

fn resultMbps(result: protocol.Result) f64 {
    if (result.elapsed_ns == 0) return 0;
    const bytes = @max(result.sent_bytes, result.received_bytes);
    return (@as(f64, @floatFromInt(bytes)) * 8.0 * 1000.0) /
        @as(f64, @floatFromInt(result.elapsed_ns));
}
