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
                    const Harness = test_utils.Harness(lib);
                    const Stream = fd_mod.Stream(lib);
                    const posix = lib.posix;
                    const testing = lib.testing;
                    var ctx_api = try Context.init(a);
                    defer ctx_api.deinit();
                    var ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() + 30 * lib.time.ns_per_ms);
                    defer ctx.deinit();

                    var listener = try Harness.listenLoopback();
                    defer listener.deinit();

                    var stream = try Stream.initSocket(posix.AF.INET);
                    defer stream.deinit();
                    try stream.connect(listener.addr());

                    const peer = try Harness.accept(listener.fd);
                    defer posix.close(peer);

                    try stream.setReadContext(ctx);
                    defer stream.setReadContext(null) catch unreachable;

                    var buf: [16]u8 = undefined;
                    try testing.expectError(error.DeadlineExceeded, stream.read(&buf));
                }
            };
            Body.call(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
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
