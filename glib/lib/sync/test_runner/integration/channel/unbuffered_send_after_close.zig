const stdz = @import("stdz");
const testing_api = @import("testing");
const Channel = @import("../../../Channel.zig");
const suite_mod = @import("suite.zig");

pub fn make(comptime std: type, comptime time: type, comptime ChannelFactory: Channel.FactoryType) testing_api.TestRunner {
    const Suite = suite_mod.Suite(std, time, ChannelFactory);
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 98304 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            Suite.testUnbufferedSendAfterClose(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            std.testing.allocator.destroy(self);
        }
    };

    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
