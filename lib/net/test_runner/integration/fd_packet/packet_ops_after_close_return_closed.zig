const embed = @import("embed");
const fd_mod = @import("../../../fd.zig");
const netip = @import("../../../netip.zig");
const testing_api = @import("testing");

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
                    const Packet = fd_mod.Packet(lib);
                    const AddrPort = netip.AddrPort;
                    const posix = lib.posix;
                    const testing = lib.testing;
                    var packet = try Packet.initSocket(posix.AF.INET);
                    packet.close();

                    var buf: [1]u8 = undefined;
                    try testing.expectError(error.Closed, packet.read(&buf));
                    try testing.expectError(error.Closed, packet.readFrom(&buf));
                    try testing.expectError(error.Closed, packet.write("x"));
                    try testing.expectError(error.Closed, packet.writeTo("x", AddrPort.from4(.{ 127, 0, 0, 1 }, 1)));
                    try testing.expectError(error.Closed, packet.connect(AddrPort.from4(.{ 127, 0, 0, 1 }, 1)));
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
