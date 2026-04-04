//! xfer test runner — protocol-level checks with fake transports.
//!
//! This file is the suite entrypoint only. Concrete cases and shared fake
//! transport helpers live under `bt/test_runner/xfer/`.

const embed = @import("embed");
const testing_api = @import("testing");
const read_send_happy = @import("xfer/read_send_happy.zig");
const read_send_retry = @import("xfer/read_send_retry.zig");
const read_send_timeout = @import("xfer/read_send_timeout.zig");
const write_recv_happy = @import("xfer/write_recv_happy.zig");
const write_recv_retry = @import("xfer/write_recv_retry.zig");
const write_recv_timeout = @import("xfer/write_recv_timeout.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("read_send/happy_path", read_send_happy.make(lib, Channel));
            t.run("read_send/retry_missing_chunk", read_send_retry.make(lib, Channel));
            t.run("read_send/timeout", read_send_timeout.make(lib, Channel));
            t.run("write_recv/happy_path", write_recv_happy.make(lib, Channel));
            t.run("write_recv/retry_missing_chunk", write_recv_retry.make(lib, Channel));
            t.run("write_recv/timeout", write_recv_timeout.make(lib, Channel));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

pub fn run(comptime lib: type, comptime Channel: fn (type) type) !void {
    try read_send_happy.run(lib, Channel, lib.testing.allocator);
    try read_send_retry.run(lib, Channel, lib.testing.allocator);
    try read_send_timeout.run(lib, Channel, lib.testing.allocator);
    try write_recv_happy.run(lib, Channel, lib.testing.allocator);
    try write_recv_retry.run(lib, Channel, lib.testing.allocator);
    try write_recv_timeout.run(lib, Channel, lib.testing.allocator);
}
