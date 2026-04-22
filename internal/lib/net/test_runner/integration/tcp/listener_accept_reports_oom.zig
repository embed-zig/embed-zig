const embed = @import("embed");
const testing_api = @import("testing");
const net = @import("../../../../net.zig");
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
                    const Net = net.make(lib);
                    const OneShotAllocator = test_utils.OneShotAllocatorType(lib);

                    var oom_alloc = OneShotAllocator{ .backing = a };
                    var ln = try Net.TcpListener.init(oom_alloc.allocator(), .{
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer ln.deinit();
                    try ln.listen();

                    const bound_port = try test_utils.listenerPort(ln, Net);
                    var cc = try Net.dial(a, .tcp, test_utils.addr4(.{ 127, 0, 0, 1 }, bound_port));
                    defer cc.deinit();

                    try lib.testing.expectError(error.OutOfMemory, ln.accept());
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
