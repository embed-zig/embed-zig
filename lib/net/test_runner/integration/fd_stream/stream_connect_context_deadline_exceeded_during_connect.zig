const context_mod = @import("context");
const embed = @import("embed");
const fd_mod = @import("../../../fd.zig");
const netip = @import("../../../netip.zig");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Context = context_mod.make(lib);
                    const Stream = fd_mod.Stream(lib);
                    const Addr = netip.AddrPort;
                    const posix = lib.posix;
                    var ctx_api = try Context.init(a);
                    defer ctx_api.deinit();

                    var ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() + 40 * lib.time.ns_per_ms);
                    defer ctx.deinit();

                    var stream = try Stream.initSocket(posix.AF.INET);
                    defer stream.deinit();

                    stream.connectContext(ctx, Addr.from4(.{ 203, 0, 113, 1 }, 9)) catch |err| switch (err) {
                        error.DeadlineExceeded => return,
                        else => return test_utils.skipIfConnectDidNotPend(err),
                    };

                    return error.ExpectedDeadlineExceeded;
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

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
