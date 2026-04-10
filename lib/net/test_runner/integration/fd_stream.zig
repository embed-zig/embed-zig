//! fd stream test runner — validates the internal non-blocking stream layer.

const embed = @import("embed");
const testing_api = @import("testing");

const stream_connect_loopback = @import("fd_stream/stream_connect_loopback.zig");
const stream_connect_context_loopback = @import("fd_stream/stream_connect_context_loopback.zig");
const stream_connect_context_canceled_before_start = @import("fd_stream/stream_connect_context_canceled_before_start.zig");
const stream_connect_context_deadline_exceeded_before_start = @import("fd_stream/stream_connect_context_deadline_exceeded_before_start.zig");
const stream_connect_context_canceled_during_connect = @import("fd_stream/stream_connect_context_canceled_during_connect.zig");
const stream_connect_context_deadline_exceeded_during_connect = @import("fd_stream/stream_connect_context_deadline_exceeded_during_connect.zig");
const stream_connect_refused_keeps_specific_error = @import("fd_stream/stream_connect_refused_keeps_specific_error.zig");
const stream_read_waits_until_readable = @import("fd_stream/stream_read_waits_until_readable.zig");
const stream_write_waits_until_writable = @import("fd_stream/stream_write_waits_until_writable.zig");
const stream_full_duplex_concurrent_streaming = @import("fd_stream/stream_full_duplex_concurrent_streaming.zig");
const stream_read_deadline_times_out = @import("fd_stream/stream_read_deadline_times_out.zig");
const stream_read_context_canceled_while_blocked = @import("fd_stream/stream_read_context_canceled_while_blocked.zig");
const stream_read_context_deadline_exceeded_while_blocked = @import("fd_stream/stream_read_context_deadline_exceeded_while_blocked.zig");
const stream_write_deadline_times_out = @import("fd_stream/stream_write_deadline_times_out.zig");
const stream_write_context_canceled_while_blocked = @import("fd_stream/stream_write_context_canceled_while_blocked.zig");
const stream_write_context_deadline_exceeded_while_blocked = @import("fd_stream/stream_write_context_deadline_exceeded_while_blocked.zig");
const stream_read_deadline_clear_allows_later_read = @import("fd_stream/stream_read_deadline_clear_allows_later_read.zig");
const stream_ops_after_close_return_closed = @import("fd_stream/stream_ops_after_close_return_closed.zig");
const stream_close_is_idempotent = @import("fd_stream/stream_close_is_idempotent.zig");

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
            t.run("streamConnectLoopback", stream_connect_loopback.make(lib));
            t.run("streamConnectContextLoopback", stream_connect_context_loopback.make(lib));
            t.run("streamConnectContextCanceledBeforeStart", stream_connect_context_canceled_before_start.make(lib));
            t.run("streamConnectContextDeadlineExceededBeforeStart", stream_connect_context_deadline_exceeded_before_start.make(lib));
            t.run("streamConnectContextCanceledDuringConnect", stream_connect_context_canceled_during_connect.make(lib));
            t.run("streamConnectContextDeadlineExceededDuringConnect", stream_connect_context_deadline_exceeded_during_connect.make(lib));
            t.run("streamConnectRefusedKeepsSpecificError", stream_connect_refused_keeps_specific_error.make(lib));
            t.run("streamReadWaitsUntilReadable", stream_read_waits_until_readable.make(lib));
            t.run("streamWriteWaitsUntilWritable", stream_write_waits_until_writable.make(lib));
            t.run("streamFullDuplexConcurrentStreaming", stream_full_duplex_concurrent_streaming.make(lib));
            t.run("streamReadDeadlineTimesOut", stream_read_deadline_times_out.make(lib));
            t.run("streamReadContextCanceledWhileBlocked", stream_read_context_canceled_while_blocked.make(lib));
            t.run("streamReadContextDeadlineExceededWhileBlocked", stream_read_context_deadline_exceeded_while_blocked.make(lib));
            t.run("streamWriteDeadlineTimesOut", stream_write_deadline_times_out.make(lib));
            t.run("streamWriteContextCanceledWhileBlocked", stream_write_context_canceled_while_blocked.make(lib));
            t.run("streamWriteContextDeadlineExceededWhileBlocked", stream_write_context_deadline_exceeded_while_blocked.make(lib));
            t.run("streamReadDeadlineClearAllowsLaterRead", stream_read_deadline_clear_allows_later_read.make(lib));
            t.run("streamOpsAfterCloseReturnClosed", stream_ops_after_close_return_closed.make(lib));
            t.run("streamCloseIsIdempotent", stream_close_is_idempotent.make(lib));
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
