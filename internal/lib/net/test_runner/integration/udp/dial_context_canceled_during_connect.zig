const stdz = @import("stdz");
const context_mod = @import("context");
const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
const test_utils = @import("../tcp/test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Net = net_mod.make(lib);
                    const Context = context_mod.make(lib);
                    const Thread = lib.Thread;

                    var ctx_api = try Context.init(a);
                    defer ctx_api.deinit();

                    var cancel_ctx = try ctx_api.withCancel(ctx_api.background());
                    defer cancel_ctx.deinit();

                    const d = Net.Dialer.init(a, .{});
                    const cancel_thread = try Thread.spawn(.{}, struct {
                        fn run(ctx: context_mod.Context, comptime thread_lib: type) void {
                            thread_lib.Thread.sleep(40 * thread_lib.time.ns_per_ms);
                            ctx.cancel();
                        }
                    }.run, .{ cancel_ctx, lib });
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
