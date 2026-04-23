const std = @import("std");
const stdz = @import("stdz");
const testing_api = @import("testing");

pub fn make(comptime Net2: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Body = struct {
                fn signalReadLater(sock: *Net2.Runtime.Tcp) void {
                    std.Thread.sleep(20 * std.time.ns_per_ms);
                    sock.signal(.read_interrupt);
                }

                fn call() !void {
                    const Runtime = Net2.Runtime;

                    var tcp = try Runtime.tcp(.inet);
                    defer tcp.close();

                    var signal_thread = try std.Thread.spawn(.{}, signalReadLater, .{&tcp});
                    defer signal_thread.join();

                    const first = try tcp.poll(.{ .read_interrupt = true }, 100);
                    try std.testing.expect(first.read_interrupt);

                    const second = try tcp.poll(.{ .read_interrupt = true }, 0);
                    try std.testing.expect(second.read_interrupt);
                }
            };

            Body.call() catch |err| {
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
