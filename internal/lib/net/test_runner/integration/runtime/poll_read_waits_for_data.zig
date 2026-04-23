const std = @import("std");
const stdz = @import("stdz");
const testing_api = @import("testing");
const net = @import("../../../../net.zig");

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
                fn waitConnect(sock: *Net2.Runtime.Tcp) !void {
                    _ = try sock.poll(.{ .write = true, .failed = true, .hup = true, .write_interrupt = true }, 1000);
                    try sock.finishConnect();
                }

                fn waitAccept(listener: *Net2.Runtime.Tcp) !Net2.Runtime.Tcp {
                    while (true) {
                        return listener.accept(null) catch |err| switch (err) {
                            error.WouldBlock => {
                                _ = try listener.poll(.{ .read = true, .read_interrupt = true }, 1000);
                                continue;
                            },
                            else => return err,
                        };
                    }
                }

                fn sendLater(sock: *Net2.Runtime.Tcp) void {
                    std.Thread.sleep(20 * std.time.ns_per_ms);
                    _ = sock.send("x") catch {};
                }

                fn call() !void {
                    const Runtime = Net2.Runtime;

                    var listener = try Runtime.tcp(.inet);
                    defer listener.close();

                    try listener.setOpt(.{ .socket = .{ .reuse_addr = true } });
                    try listener.bind(net.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    try listener.listen(8);

                    const listen_addr = try listener.localAddr();

                    var client = try Runtime.tcp(.inet);
                    defer client.close();
                    try client.connect(listen_addr);
                    try waitConnect(&client);

                    var server = try waitAccept(&listener);
                    defer server.close();

                    var sender = try std.Thread.spawn(.{}, sendLater, .{&client});
                    defer sender.join();

                    const ready = try server.poll(.{ .read = true }, 1000);
                    try std.testing.expect(ready.read);

                    var buf: [1]u8 = undefined;
                    const n = try server.recv(&buf);
                    try std.testing.expectEqual(@as(usize, 1), n);
                    try std.testing.expectEqual(@as(u8, 'x'), buf[0]);
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
