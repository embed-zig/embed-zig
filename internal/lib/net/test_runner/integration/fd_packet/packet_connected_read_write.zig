const stdz = @import("stdz");
const netip = @import("../../../netip.zig");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const Body = struct {
                fn call() !void {
                    const Harness = test_utils.Harness(lib);
                    const AddrPort = netip.AddrPort;
                    const testing = lib.testing;
                    var server = try Harness.bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    defer server.deinit();
                    var client = try Harness.bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    defer client.deinit();

                    const server_addr = try Harness.localAddr(&server);
                    const client_addr = try Harness.localAddr(&client);
                    try client.connect(server_addr);
                    try server.connect(client_addr);

                    _ = try client.write("ping");
                    var buf: [16]u8 = undefined;
                    const n1 = try server.read(&buf);
                    try testing.expectEqualStrings("ping", buf[0..n1]);

                    _ = try server.write("pong");
                    const n2 = try client.read(&buf);
                    try testing.expectEqualStrings("pong", buf[0..n2]);
                }
            };
            Body.call() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
