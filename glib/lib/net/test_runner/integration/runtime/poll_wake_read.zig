const testing_api = @import("testing");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Body = struct {
                fn signalReadLater(sock: *net.Runtime.Tcp) void {
                    std.Thread.sleep(@intCast(20 * net.time.duration.MilliSecond));
                    sock.signal(.read_interrupt);
                }

                fn call() !void {
                    const Runtime = net.Runtime;

                    var tcp = try Runtime.tcp(.inet);
                    defer {
                        tcp.close();
                        tcp.deinit();
                    }

                    var signal_thread = try std.Thread.spawn(.{}, signalReadLater, .{&tcp});
                    defer signal_thread.join();

                    const first = try tcp.poll(.{ .read_interrupt = true }, @intCast(100 * net.time.duration.MilliSecond));
                    try std.testing.expect(first.read_interrupt);

                    try std.testing.expectError(error.TimedOut, tcp.poll(.{ .read_interrupt = true }, 0));
                }
            };

            Body.call() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
