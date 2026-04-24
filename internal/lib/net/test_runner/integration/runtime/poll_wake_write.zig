const std = @import("std");
const testing_api = @import("testing");

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Body = struct {
                fn signalWriteLater(sock: *net.Runtime.Tcp) void {
                    std.Thread.sleep(20 * std.time.ns_per_ms);
                    sock.signal(.write_interrupt);
                }

                fn call() !void {
                    const Runtime = net.Runtime;

                    var tcp = try Runtime.tcp(.inet);
                    defer {
                        tcp.close();
                        tcp.deinit();
                    }

                    var signal_thread = try std.Thread.spawn(.{}, signalWriteLater, .{&tcp});
                    defer signal_thread.join();

                    const first = try tcp.poll(.{ .write_interrupt = true }, 100);
                    try std.testing.expect(first.write_interrupt);

                    try std.testing.expectError(error.TimedOut, tcp.poll(.{ .write_interrupt = true }, 0));
                }
            };

            Body.call() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
