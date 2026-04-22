const context_mod = @import("context");
const stdz = @import("stdz");
const fd_mod = @import("../../../fd.zig");
const netip = @import("../../../netip.zig");
const testing_api = @import("testing");
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
                    const Context = context_mod.make(lib);
                    const Packet = fd_mod.Packet(lib);
                    const AddrPort = netip.AddrPort;
                    const posix = lib.posix;
                    const Thread = lib.Thread;
                    var ctx_api = try Context.init(a);
                    defer ctx_api.deinit();

                    var ctx = try ctx_api.withCancel(ctx_api.background());
                    defer ctx.deinit();

                    var packet = try Packet.initSocket(posix.AF.INET);
                    defer packet.deinit();

                    const cancel_thread = try Thread.spawn(.{}, struct {
                        fn run(cancel_ctx: context_mod.Context, comptime thread_lib: type) void {
                            thread_lib.Thread.sleep(40 * thread_lib.time.ns_per_ms);
                            cancel_ctx.cancel();
                        }
                    }.run, .{ ctx, lib });
                    defer cancel_thread.join();

                    packet.connectContext(ctx, AddrPort.from4(.{ 203, 0, 113, 1 }, 9)) catch |err| switch (err) {
                        error.Canceled => return,
                        else => return test_utils.skipIfConnectDidNotPend(err),
                    };

                    // UDP connect may complete synchronously on some hosts because there
                    // is no handshake to force an in-progress state.
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
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
