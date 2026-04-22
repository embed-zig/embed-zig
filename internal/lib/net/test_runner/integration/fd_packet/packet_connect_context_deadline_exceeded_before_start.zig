const context_mod = @import("context");
const stdz = @import("stdz");
const fd_mod = @import("../../../fd.zig");
const netip = @import("../../../netip.zig");
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
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Context = context_mod.make(lib);
                    const Packet = fd_mod.Packet(lib);
                    const AddrPort = netip.AddrPort;
                    const posix = lib.posix;
                    const testing = lib.testing;
                    var ctx_api = try Context.init(a);
                    defer ctx_api.deinit();

                    var ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() - 1 * lib.time.ns_per_ms);
                    defer ctx.deinit();

                    var packet = try Packet.initSocket(posix.AF.INET);
                    defer packet.deinit();

                    try testing.expectError(
                        error.DeadlineExceeded,
                        packet.connectContext(ctx, AddrPort.from4(.{ 127, 0, 0, 1 }, 1)),
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
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
