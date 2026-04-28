const stdz = @import("stdz");
const context_mod = @import("context");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: std.mem.Allocator) !void {
                    const Net = net;
                    const Context = context_mod.make(std, net.time);

                    var ctx_api = try Context.init(a);
                    defer ctx_api.deinit();

                    var deadline_ctx = try ctx_api.withTimeout(ctx_api.background(), -1 * @import("time").duration.MilliSecond);
                    defer deadline_ctx.deinit();

                    var d = Net.Dialer.init(a, .{});
                    try std.testing.expectError(
                        error.DeadlineExceeded,
                        d.dialContext(deadline_ctx, .tcp, test_utils.addr4(.{ 127, 0, 0, 1 }, 1)),
                    );
                }
            };
            Body.call(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
