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
                fn expectAddrEq(a: net.netip.AddrPort, b: net.netip.AddrPort) !void {
                    try host_std.testing.expectEqual(a.port(), b.port());
                    if (a.addr().as4()) |a4| {
                        const b4 = b.addr().as4().?;
                        try host_std.testing.expectEqualSlices(u8, &a4, &b4);
                        return;
                    }
                    const a16 = a.addr().as16().?;
                    const b16 = b.addr().as16().?;
                    try host_std.testing.expectEqualSlices(u8, &a16, &b16);
                }

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

                fn waitAccept(listener: *net.Runtime.Tcp, remote: *net.netip.AddrPort) !net.Runtime.Tcp {
                    while (true) {
                        return listener.accept(remote) catch |err| switch (err) {
                            error.WouldBlock => {
                                _ = try listener.poll(.{ .read = true, .read_interrupt = true }, @intCast(1000 * net.time.duration.MilliSecond));
                                continue;
                            },
                            else => return err,
                        };
                    }
                }

                fn sendAll(sock: *net.Runtime.Tcp, buf: []const u8) !void {
                    var off: usize = 0;
                    while (off < buf.len) {
                        const n = sock.send(buf[off..]) catch |err| switch (err) {
                            error.WouldBlock => {
                                _ = try sock.poll(.{ .write = true, .write_interrupt = true }, @intCast(1000 * net.time.duration.MilliSecond));
                                continue;
                            },
                            else => return err,
                        };
                        off += n;
                    }
                }

                fn recvExact(sock: *net.Runtime.Tcp, buf: []u8) !void {
                    var off: usize = 0;
                    while (off < buf.len) {
                        const n = sock.recv(buf[off..]) catch |err| switch (err) {
                            error.WouldBlock => {
                                _ = try sock.poll(.{ .read = true, .read_interrupt = true, .hup = true }, @intCast(1000 * net.time.duration.MilliSecond));
                                continue;
                            },
                            else => return err,
                        };
                        if (n == 0) return error.UnexpectedEof;
                        off += n;
                    }
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
                    try host_std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &listen_addr.addr().as4().?);
                    try host_std.testing.expect(listen_addr.port() != 0);

                    var client = try Runtime.tcp(.inet);
                    defer {
                        client.close();
                        client.deinit();
                    }

                    try startConnect(&client, listen_addr);
                    try waitConnect(&client);

                    const client_local = try client.localAddr();
                    const client_remote = try client.remoteAddr();
                    try expectAddrEq(client_remote, listen_addr);

                    var accepted_remote: net.netip.AddrPort = undefined;
                    var server = try waitAccept(&listener, &accepted_remote);
                    defer {
                        server.close();
                        server.deinit();
                    }

                    try expectAddrEq(accepted_remote, client_local);
                    try expectAddrEq(try server.localAddr(), listen_addr);
                    try expectAddrEq(try server.remoteAddr(), client_local);

                    const request = "hello runtime tcp";
                    try sendAll(&client, request);

                    var req_buf: [request.len]u8 = undefined;
                    try recvExact(&server, &req_buf);
                    try host_std.testing.expectEqualStrings(request, &req_buf);

                    const response = "pong runtime tcp";
                    try sendAll(&server, response);

                    var resp_buf: [response.len]u8 = undefined;
                    try recvExact(&client, &resp_buf);
                    try host_std.testing.expectEqualStrings(response, &resp_buf);
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
