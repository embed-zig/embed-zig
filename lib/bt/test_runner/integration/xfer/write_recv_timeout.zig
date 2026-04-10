const testing_api = @import("testing");
const harness_mod = @import("harness.zig");
const recv_mod = @import("../../../host/xfer/recv.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 96 * 1024, struct {
        fn run(t: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = t;
            try runCase(lib, Channel, allocator);
        }
    }.run);
}

pub fn run(comptime lib: type, comptime Channel: fn (type) type, allocator: lib.mem.Allocator) !void {
    try runCase(lib, Channel, allocator);
}

fn runCase(comptime lib: type, comptime Channel: fn (type) type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const Harness = harness_mod.make(lib, Channel);

    var harness = try Harness.init(allocator);
    defer harness.deinit();

    var server = harness.right();
    try testing.expectError(error.Timeout, recv_mod.recv(lib, allocator, &server, .{
        .att_mtu = 23,
        .timeout_ms = 5,
        .max_timeout_retries = 2,
    }));
}
