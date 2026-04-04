const embed = @import("embed");
const testing_api = @import("testing");
const harness_mod = @import("harness.zig");
const recv_mod = @import("../../host/xfer/recv.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            runCase(lib, Channel, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
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

pub fn run(comptime lib: type, comptime ChannelFactory: fn (type) type, allocator: lib.mem.Allocator) !void {
    try runCase(lib, ChannelFactory, allocator);
}

fn runCase(comptime lib: type, comptime ChannelFactory: fn (type) type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const Harness = harness_mod.make(lib, ChannelFactory);

    var harness = try Harness.init(allocator);
    defer harness.deinit();

    var server = harness.right();
    try testing.expectError(error.Timeout, recv_mod.recv(lib, allocator, &server, .{
        .att_mtu = 23,
        .timeout_ms = 5,
        .max_timeout_retries = 2,
    }));
}
