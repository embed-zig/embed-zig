const testing_api = @import("testing");
const Channel = @import("../Channel.zig");

pub const channel = @import("integration/channel.zig");
pub const racer = @import("integration/racer.zig");

pub fn make(comptime std: type, comptime time: type, comptime ChannelFactory: Channel.FactoryType) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("channel", channel.make(std, time, ChannelFactory));
            t.run("racer", racer.make(std, time));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
