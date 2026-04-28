const host_std = @import("std");
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
                fn waitConnect(sock: *net.Runtime.Tcp) !void {
                    _ = try sock.poll(.{ .write = true, .failed = true, .hup = true, .write_interrupt = true }, @intCast(1000 * net.time.duration.MilliSecond));
                    try sock.finishConnect();
                }

                fn startConnect(sock: *net.Runtime.Tcp, addr: net.netip.AddrPort) !void {
                    sock.connect(addr) catch |err| switch (err) {
                        error.ConnectionPending, error.WouldBlock => {},
                        else => return err,
                    };
                }

                fn waitAccept(listener: *net.Runtime.Tcp) !net.Runtime.Tcp {
                    while (true) {
                        return listener.accept(null) catch |err| switch (err) {
                            error.WouldBlock => {
                                _ = try listener.poll(.{ .read = true, .read_interrupt = true }, @intCast(1000 * net.time.duration.MilliSecond));
                                continue;
                            },
                            else => return err,
                        };
                    }
                }

                fn sendLater(sock: *net.Runtime.Tcp) void {
                    host_std.Thread.sleep(@intCast(20 * net.time.duration.MilliSecond));
                    _ = sock.send("x") catch {};
                }

                fn call() !void {
                    const Runtime = net.Runtime;

                    var listener = try Runtime.tcp(.inet);
                    defer {
                        listener.close();
                        listener.deinit();
                    }

                    try listener.setOpt(.{ .socket = .{ .reuse_addr = true } });
                    try listener.bind(net.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    try listener.listen(8);

                    const listen_addr = try listener.localAddr();

                    var client = try Runtime.tcp(.inet);
                    defer {
                        client.close();
                        client.deinit();
                    }
                    try startConnect(&client, listen_addr);
                    try waitConnect(&client);

                    var server = try waitAccept(&listener);
                    defer {
                        server.close();
                        server.deinit();
                    }

                    var sender = try host_std.Thread.spawn(.{}, sendLater, .{&client});
                    defer sender.join();

                    const started = net.time.instant.now();
                    const ready = try server.poll(.{ .read = true }, @intCast(1000 * net.time.duration.MilliSecond));
                    const elapsed_ms = @divFloor(@import("time").instant.sub(net.time.instant.now(), started), net.time.duration.MilliSecond);
                    try host_std.testing.expect(ready.read);
                    try host_std.testing.expect(elapsed_ms >= 10);

                    var buf: [1]u8 = undefined;
                    const n = try server.recv(&buf);
                    try host_std.testing.expectEqual(@as(usize, 1), n);
                    try host_std.testing.expectEqual(@as(u8, 'x'), buf[0]);
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
