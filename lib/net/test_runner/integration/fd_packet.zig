//! fd packet test runner — validates the internal non-blocking packet layer.

const embed = @import("embed");
const testing_api = @import("testing");

const packet_ipv4_loopback = @import("fd_packet/packet_ipv4_loopback.zig");
const packet_ipv6_loopback = @import("fd_packet/packet_ipv6_loopback.zig");
const packet_connected_read_write = @import("fd_packet/packet_connected_read_write.zig");
const packet_connect_context_loopback = @import("fd_packet/packet_connect_context_loopback.zig");
const packet_connect_context_canceled_before_start = @import("fd_packet/packet_connect_context_canceled_before_start.zig");
const packet_connect_context_deadline_exceeded_before_start = @import("fd_packet/packet_connect_context_deadline_exceeded_before_start.zig");
const packet_connect_context_canceled_during_connect = @import("fd_packet/packet_connect_context_canceled_during_connect.zig");
const packet_connect_context_deadline_exceeded_during_connect = @import("fd_packet/packet_connect_context_deadline_exceeded_during_connect.zig");
const packet_preserves_datagram_boundaries = @import("fd_packet/packet_preserves_datagram_boundaries.zig");
const packet_read_deadline_times_out = @import("fd_packet/packet_read_deadline_times_out.zig");
const packet_read_deadline_clear_allows_later_read = @import("fd_packet/packet_read_deadline_clear_allows_later_read.zig");
const packet_full_duplex_streaming = @import("fd_packet/packet_full_duplex_streaming.zig");
const packet_ops_after_close_return_closed = @import("fd_packet/packet_ops_after_close_return_closed.zig");
const packet_close_is_idempotent = @import("fd_packet/packet_close_is_idempotent.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("packetIpv4Loopback", packet_ipv4_loopback.make(lib));
            t.run("packetIpv6Loopback", packet_ipv6_loopback.make(lib));
            t.run("packetConnectedReadWrite", packet_connected_read_write.make(lib));
            t.run("packetConnectContextLoopback", packet_connect_context_loopback.make(lib));
            t.run("packetConnectContextCanceledBeforeStart", packet_connect_context_canceled_before_start.make(lib));
            t.run("packetConnectContextDeadlineExceededBeforeStart", packet_connect_context_deadline_exceeded_before_start.make(lib));
            t.run("packetConnectContextCanceledDuringConnect", packet_connect_context_canceled_during_connect.make(lib));
            t.run("packetConnectContextDeadlineExceededDuringConnect", packet_connect_context_deadline_exceeded_during_connect.make(lib));
            t.run("packetPreservesDatagramBoundaries", packet_preserves_datagram_boundaries.make(lib));
            t.run("packetReadDeadlineTimesOut", packet_read_deadline_times_out.make(lib));
            t.run("packetReadDeadlineClearAllowsLaterRead", packet_read_deadline_clear_allows_later_read.make(lib));
            t.run("packetFullDuplexStreaming", packet_full_duplex_streaming.make(lib));
            t.run("packetOpsAfterCloseReturnClosed", packet_ops_after_close_return_closed.make(lib));
            t.run("packetCloseIsIdempotent", packet_close_is_idempotent.make(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
