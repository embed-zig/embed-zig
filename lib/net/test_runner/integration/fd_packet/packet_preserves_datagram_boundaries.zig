const embed = @import("embed");
const netip = @import("../../../netip.zig");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
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
                    _ = try sender.writeTo("abcdef", dest);
                    _ = try sender.writeTo("xy", dest);

                    var first: [8]u8 = undefined;
                    const r1 = try receiver.readFrom(&first);
                    try testing.expectEqualStrings("abcdef", first[0..r1.bytes_read]);

                    var second: [8]u8 = undefined;
                    const r2 = try receiver.readFrom(&second);
                    try testing.expectEqualStrings("xy", second[0..r2.bytes_read]);
                }
            };
            Body.call() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
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
