const stdz = @import("stdz");
const fd_mod = @import("../../../fd.zig");
const testing_api = @import("testing");

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
                    const Packet = fd_mod.Packet(lib);
                    const posix = lib.posix;
                    const testing = lib.testing;
                    var packet = try Packet.initSocket(posix.AF.INET);
                    packet.close();
                    packet.close();

                    var buf: [1]u8 = undefined;
                    try testing.expectError(error.Closed, packet.readFrom(&buf));
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
