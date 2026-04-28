const context_mod = @import("context");
const stdz = @import("stdz");
const testing_api = @import("testing");
const tcp_test_utils = @import("../tcp/test_utils.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

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
                    var context_api = try Context.init(a);
                    defer context_api.deinit();

                    var cancel_ctx = try context_api.withCancel(context_api.background());
                    defer cancel_ctx.deinit();
                    cancel_ctx.cancel();

                    try std.testing.expectError(error.Canceled, Net.tls.dialContext(
                        cancel_ctx,
                        a,
                        .tcp,
                        tcp_test_utils.addr4(.{ 127, 0, 0, 1 }, 1),
                        .{
                            .server_name = "example.com",
                            .verification = .self_signed,
                        },
                    ));
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
