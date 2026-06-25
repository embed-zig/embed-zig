const glib = @import("glib");

pub const ikcp_memory = @import("benchmark/ikcp_memory.zig");
pub const ikcp_udp = @import("benchmark/ikcp_udp.zig");
pub const session_udp = @import("benchmark/session_udp.zig");

pub const default_bytes = ikcp_memory.default_bytes;
pub const default_udp_payload = ikcp_memory.default_udp_payload;
pub const default_window = ikcp_memory.default_window;
pub const default_interval_ms = ikcp_memory.default_interval_ms;

pub const Config = ikcp_memory.Config;
pub const Scenario = ikcp_memory.Scenario;
pub const Result = ikcp_memory.Result;
pub const UdpResult = ikcp_udp.Result;
pub const SessionUdpResult = session_udp.Result;

pub fn Runner(comptime grt: type) type {
    const MemoryRunner = ikcp_memory.Runner(grt);
    const UdpRunner = ikcp_udp.Runner(grt);
    const SessionUdpRunner = session_udp.Runner(grt);

    return struct {
        pub fn runAll(allocator: grt.std.mem.Allocator, config: Config, out: []Result) !usize {
            return MemoryRunner.runAll(allocator, config, out);
        }

        pub fn runLocalhostUdpRtt(allocator: grt.std.mem.Allocator, config: Config, rtt_ms: u32) !UdpResult {
            return UdpRunner.runLocalhostRtt(allocator, config, rtt_ms);
        }

        pub fn runLocalhostSessionUp(allocator: grt.std.mem.Allocator, config: Config) !SessionUdpResult {
            return SessionUdpRunner.runLocalhostUp(allocator, config);
        }
    };
}

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const RunnerImpl = Runner(grt);
    const Test = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            var results: [3]Result = undefined;
            const len = RunnerImpl.runAll(allocator, .{}, results[0..]) catch |err| {
                t.logErrorf("ikcp-memory benchmark failed: {s}", .{@errorName(err)});
                return false;
            };
            for (results[0..len]) |result| {
                t.logInfof(
                    "ikcp-memory {s} elapsed_ns={d} mbps={d:.3} sent={d} recv={d} output_packets={d} output_bytes={d} output_drops={d} input_errors={d}",
                    .{
                        result.scenario.label(),
                        result.elapsed_ns,
                        result.mbps(),
                        result.sent_bytes,
                        result.received_bytes,
                        result.output_packets,
                        result.output_bytes,
                        result.output_drops,
                        result.input_errors,
                    },
                );
                if (result.received_bytes == 0 or result.input_errors != 0 or result.output_drops != 0) {
                    return false;
                }
            }

            const udp_config = Config{ .bytes = 1024 * 1024 };
            const rtts = [_]u32{ 0, 25 };
            const native_std = @import("std");
            for (rtts) |rtt_ms| {
                const result = RunnerImpl.runLocalhostUdpRtt(allocator, udp_config, rtt_ms) catch |err| {
                    t.logErrorf("ikcp-udp benchmark failed rtt_ms={d}: {s}", .{ rtt_ms, @errorName(err) });
                    return false;
                };
                native_std.debug.print(
                    "ikcp-udp localhost rtt_ms={d} elapsed_ns={d} mbps={d:.3} sent={d} recv={d} out={d}/{d}B sock={d}/{d} drop={d} input_err={d} loop={d} ksend={d} kin={d} kupd={d} krecv={d} sleep={d}/{d}ms max_wait={d} max_infl={d} max_out_burst={d} max_sock_send_burst={d} max_sock_recv_burst={d} max_q={d}\n",
                    .{
                        result.rtt_ms,
                        result.elapsed_ns,
                        result.mbps(),
                        result.sent_bytes,
                        result.received_bytes,
                        result.output_packets,
                        result.output_bytes,
                        result.socket_send_packets,
                        result.socket_recv_packets,
                        result.output_drops,
                        result.input_errors,
                        result.loop_iterations,
                        result.kcp_send_calls,
                        result.kcp_input_calls,
                        result.kcp_update_calls,
                        result.kcp_recv_calls,
                        result.sleep_calls,
                        result.sleep_ms,
                        result.max_waitsnd,
                        result.max_inflight,
                        result.max_output_burst,
                        result.max_socket_send_burst,
                        result.max_socket_recv_burst,
                        result.max_send_queue_depth,
                    },
                );
                t.logInfof(
                    "ikcp-udp localhost rtt_ms={d} elapsed_ns={d} mbps={d:.3} sent={d} recv={d} out={d}/{d}B sock={d}/{d} drop={d} input_err={d} loop={d} ksend={d} kin={d} kupd={d} krecv={d} sleep={d}/{d}ms max_wait={d} max_infl={d} max_out_burst={d} max_sock_send_burst={d} max_sock_recv_burst={d} max_q={d}",
                    .{
                        result.rtt_ms,
                        result.elapsed_ns,
                        result.mbps(),
                        result.sent_bytes,
                        result.received_bytes,
                        result.output_packets,
                        result.output_bytes,
                        result.socket_send_packets,
                        result.socket_recv_packets,
                        result.output_drops,
                        result.input_errors,
                        result.loop_iterations,
                        result.kcp_send_calls,
                        result.kcp_input_calls,
                        result.kcp_update_calls,
                        result.kcp_recv_calls,
                        result.sleep_calls,
                        result.sleep_ms,
                        result.max_waitsnd,
                        result.max_inflight,
                        result.max_output_burst,
                        result.max_socket_send_burst,
                        result.max_socket_recv_burst,
                        result.max_send_queue_depth,
                    },
                );
                if (result.received_bytes != udp_config.bytes or result.input_errors != 0 or result.output_drops != 0) {
                    return false;
                }
            }

            const session_config = Config{ .bytes = 1024 * 1024 };
            const session_result = RunnerImpl.runLocalhostSessionUp(allocator, session_config) catch |err| {
                t.logErrorf("session-udp benchmark failed: {s}", .{@errorName(err)});
                return false;
            };
            native_std.debug.print(
                "session-udp localhost up elapsed_ns={d} mbps={d:.3} client_sent={d} server_recv={d} client_out={d} client_in={d} client_xmit={d} client_drop={d} client_work_max={d}us client_upd_max={d}us client_late_max={d}us client_upd_ob={d} client_upd_write_max={d}us client_upd_core={d}us server_out={d} server_in={d} server_xmit={d}\n",
                .{
                    session_result.elapsed_ns,
                    session_result.mbps(),
                    session_result.client.sent_bytes,
                    session_result.server.received_bytes,
                    session_result.client_snapshot.output_packets,
                    session_result.client_snapshot.input_packets,
                    session_result.client_snapshot.xmit,
                    session_result.client_snapshot.output_drops,
                    session_result.client_snapshot.loop_work_max_us,
                    session_result.client_snapshot.loop_update_max_us,
                    session_result.client_snapshot.loop_late_max_us,
                    session_result.client_snapshot.loop_update_max_output_burst,
                    session_result.client_snapshot.loop_update_max_output_write_max_us,
                    session_result.client_snapshot.loop_update_max_internal_us,
                    session_result.server_snapshot.output_packets,
                    session_result.server_snapshot.input_packets,
                    session_result.server_snapshot.xmit,
                },
            );
            t.logInfof(
                "session-udp localhost up elapsed_ns={d} mbps={d:.3} client_sent={d} server_recv={d} client_out={d} client_in={d} client_xmit={d} client_drop={d} client_work_max={d}us client_upd_max={d}us client_late_max={d}us client_upd_ob={d} client_upd_write_max={d}us client_upd_core={d}us server_out={d} server_in={d} server_xmit={d}",
                .{
                    session_result.elapsed_ns,
                    session_result.mbps(),
                    session_result.client.sent_bytes,
                    session_result.server.received_bytes,
                    session_result.client_snapshot.output_packets,
                    session_result.client_snapshot.input_packets,
                    session_result.client_snapshot.xmit,
                    session_result.client_snapshot.output_drops,
                    session_result.client_snapshot.loop_work_max_us,
                    session_result.client_snapshot.loop_update_max_us,
                    session_result.client_snapshot.loop_late_max_us,
                    session_result.client_snapshot.loop_update_max_output_burst,
                    session_result.client_snapshot.loop_update_max_output_write_max_us,
                    session_result.client_snapshot.loop_update_max_internal_us,
                    session_result.server_snapshot.output_packets,
                    session_result.server_snapshot.input_packets,
                    session_result.server_snapshot.xmit,
                },
            );
            if (session_result.server.received_bytes != session_config.bytes or
                session_result.client_snapshot.output_drops != 0 or
                session_result.client_snapshot.input_errors != 0 or
                session_result.server_snapshot.output_drops != 0 or
                session_result.server_snapshot.input_errors != 0)
            {
                return false;
            }
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Test = .{};
    };
    return glib.testing.TestRunner.make(Test).new(&Holder.runner);
}
