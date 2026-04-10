const context_mod = @import("context");
const embed = @import("embed");
const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
const tcp_test_utils = @import("../tcp/test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Net = net_mod.make(lib);
                    const Context = context_mod.make(lib);
                    var context_api = try Context.init(a);
                    defer context_api.deinit();

                    var cancel_ctx = try context_api.withCancel(context_api.background());
                    defer cancel_ctx.deinit();
                    cancel_ctx.cancel();

                    try lib.testing.expectError(error.Canceled, Net.tls.dialContext(
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
