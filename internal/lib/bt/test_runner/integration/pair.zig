const embed = @import("embed");
const bt = @import("../../../bt.zig");
const pair_runner = @import("../pair.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Mocker = bt.Mocker(lib, Channel);
            var mocker = Mocker.init(lib.testing.allocator, .{});
            defer mocker.deinit();

            var host_a = mocker.createHost(.{
                .position = .{ .x = -1, .y = 0, .z = 0 },
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer host_a.deinit();

            var host_b = mocker.createHost(.{
                .position = .{ .x = 1, .y = 0, .z = 0 },
                .hci = .{
                    .controller_addr = .{ 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6 },
                    .peer_addr = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
                },
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer host_b.deinit();

            t.parallel();
            t.run("a/peripheral", pair_runner.makePeripheral(lib, &host_a));
            t.run("b/peripheral", pair_runner.makePeripheral(lib, &host_b));
            t.run("a/central", pair_runner.makeCentral(lib, &host_a));
            t.run("b/central", pair_runner.makeCentral(lib, &host_b));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
