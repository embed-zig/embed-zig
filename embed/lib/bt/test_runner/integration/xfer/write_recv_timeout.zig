const glib = @import("glib");

const harness_mod = @import("harness.zig");
const recv_mod = @import("../../../host/xfer/recv.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return glib.testing.TestRunner.fromFn(grt.std, 96 * 1024, struct {
        fn run(t: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            _ = t;
            try runCase(grt, allocator);
        }
    }.run);
}

pub fn run(comptime grt: type, allocator: glib.std.mem.Allocator) !void {
    try runCase(grt, allocator);
}

fn runCase(comptime grt: type, allocator: glib.std.mem.Allocator) !void {
    const Harness = harness_mod.make(grt);

    var harness = try Harness.init(allocator);
    defer harness.deinit();

    var server = harness.right();
    try grt.std.testing.expectError(error.Timeout, recv_mod.recv(grt, allocator, &server, .{
        .att_mtu = 23,
        .timeout = 5 * glib.time.duration.MilliSecond,
        .max_timeout_retries = 2,
    }));
}
