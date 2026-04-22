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
                    var receiver = try Harness.bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    defer receiver.deinit();
                    var sender = try Harness.bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    defer sender.deinit();

                    const dest = try Harness.localAddr(&receiver);
                    const src = try Harness.localAddr(&sender);
                    const sent = try sender.writeTo("hello packet", dest);
                    try testing.expectEqual(@as(usize, 12), sent);

                    var buf: [64]u8 = undefined;
                    const recv = try receiver.readFrom(&buf);
                    try testing.expectEqualStrings("hello packet", buf[0..recv.bytes_read]);
                    try Harness.expectFromAddrPort(recv, src.port());
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
