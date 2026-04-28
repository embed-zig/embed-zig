const stdz = @import("stdz");
const context_mod = @import("context");
const testing_api = @import("testing");
const test_utils = @import("../tcp/test_utils.zig");

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
                    const Context = context_mod.make(std, net.time);
                    const Thread = std.Thread;

                    var ctx_api = try Context.init(a);
                    defer ctx_api.deinit();

                    var cancel_ctx = try ctx_api.withCancel(ctx_api.background());
                    defer cancel_ctx.deinit();

                    const d = net.Dialer.init(a, .{});
                    const cancel_thread = try Thread.spawn(.{}, struct {
                        fn run(ctx: context_mod.Context, comptime thread_lib: type) void {
                            thread_lib.Thread.sleep(@intCast(40 * net.time.duration.MilliSecond));
                            ctx.cancel();
                        }
                    }.run, .{ cancel_ctx, std });
                    defer cancel_thread.join();

                    var conn = d.dialContext(cancel_ctx, .udp, test_utils.addr4(.{ 203, 0, 113, 1 }, 9)) catch |err| switch (err) {
                        error.Canceled => return,
                        else => return test_utils.skipIfConnectDidNotPend(err),
                    };
                    defer conn.deinit();

                    return error.SkipZigTest;
                }
            };
            Body.call(allocator) catch |err| switch (err) {
                error.SkipZigTest => return true,
                else => {
                    t.logFatal(@errorName(err));
                    return false;
                },
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
