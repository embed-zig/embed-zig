const embed = @import("embed");
const bt = @import("../../../bt.zig");
const embed_std = @import("embed_std");
const pair_xfer_runner = @import("../pair_xfer.zig");
const testing_api = @import("testing");

pub const protocol = @import("xfer/protocol.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Bt = bt.make(lib, embed_std.sync.Channel);
            const Mocker = bt.Mocker(lib);
            var mocker = Mocker.init(lib.testing.allocator, .{});
            defer mocker.deinit();

            var client_host = mocker.createHost(.{
                .position = .{ .x = -1, .y = 0, .z = 0 },
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer client_host.deinit();

            var server_host = mocker.createHost(.{
                .position = .{ .x = 1, .y = 0, .z = 0 },
                .hci = .{
                    .controller_addr = .{ 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6 },
                    .peer_addr = .{ 0x51, 0x52, 0x53, 0x54, 0x55, 0x56 },
                    .mtu = 64,
                },
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer server_host.deinit();

            t.parallel();
            t.run("protocol", protocol.make(lib));
            t.run("peripheral", pair_xfer_runner.makePeripheral(lib, Bt.Server, &server_host));
            t.run("central", pair_xfer_runner.makeCentral(lib, Bt.Client, &client_host));
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
