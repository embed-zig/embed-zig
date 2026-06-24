const glib = @import("glib");

pub const ikcp_memory = @import("benchmark/ikcp_memory.zig");
pub const ikcp_udp = @import("benchmark/ikcp_udp.zig");

pub const default_bytes = ikcp_memory.default_bytes;
pub const default_udp_payload = ikcp_memory.default_udp_payload;
pub const default_window = ikcp_memory.default_window;
pub const default_interval_ms = ikcp_memory.default_interval_ms;

pub const Config = ikcp_memory.Config;
pub const Scenario = ikcp_memory.Scenario;
pub const Result = ikcp_memory.Result;
pub const UdpResult = ikcp_udp.Result;

pub fn Runner(comptime grt: type) type {
    const MemoryRunner = ikcp_memory.Runner(grt);
    const UdpRunner = ikcp_udp.Runner(grt);

    return struct {
        pub fn runAll(allocator: grt.std.mem.Allocator, config: Config, out: []Result) !usize {
            return MemoryRunner.runAll(allocator, config, out);
        }

        pub fn runLocalhostUdpRtt(allocator: grt.std.mem.Allocator, config: Config, rtt_ms: u32) !UdpResult {
            return UdpRunner.runLocalhostRtt(allocator, config, rtt_ms);
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
