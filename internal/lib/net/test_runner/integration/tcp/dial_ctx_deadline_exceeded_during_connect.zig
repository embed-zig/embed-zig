const stdz = @import("stdz");
const context_mod = @import("context");
const testing_api = @import("testing");
const net = @import("../../../../net.zig");
const test_utils = @import("test_utils.zig");

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
                    const Net = net.make(lib);
                    const Context = context_mod.make(lib);

                    var ctx_api = try Context.init(a);
                    defer ctx_api.deinit();

                    var deadline_ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() + 40 * lib.time.ns_per_ms);
                    defer deadline_ctx.deinit();

                    const d = Net.Dialer.init(a, .{});
                    var conn = d.dialContext(deadline_ctx, .tcp, test_utils.addr4(.{ 203, 0, 113, 1 }, 9)) catch |dial_err| switch (dial_err) {
                        error.DeadlineExceeded => return,
                        else => {
                            test_utils.skipIfConnectDidNotPend(dial_err) catch |skip_err| switch (skip_err) {
                                error.SkipZigTest => return,
                                else => return skip_err,
                            };
                            unreachable;
                        },
                    };
                    defer conn.deinit();

                    return error.ExpectedDeadlineExceeded;
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
