const context_mod = @import("context");
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
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Context = context_mod.make(lib);
                    const Harness = test_utils.Harness(lib);
                    const AddrPort = netip.AddrPort;
                    const testing = lib.testing;
                    var ctx_api = try Context.init(a);
                    defer ctx_api.deinit();

                    var server = try Harness.bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    defer server.deinit();
                    var client = try Harness.bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    defer client.deinit();

                    const server_addr = try Harness.localAddr(&server);
                    try client.connectContext(ctx_api.background(), server_addr);

                    _ = try client.write("ctx");

                    var buf: [16]u8 = undefined;
                    const recv = try server.readFrom(&buf);
                    try testing.expectEqualStrings("ctx", buf[0..recv.bytes_read]);

                    const n = try server.writeTo("ok", try Harness.localAddr(&client));
                    try testing.expectEqual(@as(usize, 2), n);

                    const ack_len = try client.read(&buf);
                    try testing.expectEqualStrings("ok", buf[0..ack_len]);
                }
            };
            Body.call(allocator) catch |err| {
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
