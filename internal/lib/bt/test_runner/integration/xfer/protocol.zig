const stdz = @import("stdz");
const embed_std = @import("embed_std");
const testing_api = @import("testing");

pub const harness = @import("harness.zig");
pub const read_send_happy = @import("read_send_happy.zig");
pub const read_send_retry = @import("read_send_retry.zig");
pub const read_send_timeout = @import("read_send_timeout.zig");
pub const write_recv_happy = @import("write_recv_happy.zig");
pub const write_recv_retry = @import("write_recv_retry.zig");
pub const write_recv_timeout = @import("write_recv_timeout.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    return makeWithChannel(lib, embed_std.sync.Channel);
}

pub fn makeWithChannel(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
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

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
