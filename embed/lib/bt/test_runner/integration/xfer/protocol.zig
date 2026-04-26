const glib = @import("glib");

pub const harness = @import("harness.zig");
pub const read_send_happy = @import("read_send_happy.zig");
pub const read_send_retry = @import("read_send_retry.zig");
pub const read_send_timeout = @import("read_send_timeout.zig");
pub const write_recv_happy = @import("write_recv_happy.zig");
pub const write_recv_retry = @import("write_recv_retry.zig");
pub const write_recv_timeout = @import("write_recv_timeout.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("read_send/happy_path", read_send_happy.make(grt));
            t.run("read_send/retry_missing_chunk", read_send_retry.make(grt));
            t.run("read_send/timeout", read_send_timeout.make(grt));
            t.run("write_recv/happy_path", write_recv_happy.make(grt));
            t.run("write_recv/retry_missing_chunk", write_recv_retry.make(grt));
            t.run("write_recv/timeout", write_recv_timeout.make(grt));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
