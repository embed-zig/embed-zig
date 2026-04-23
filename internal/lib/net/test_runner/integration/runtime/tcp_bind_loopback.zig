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
                fn expectAddrEq(a: net.netip.AddrPort, b: net.netip.AddrPort) !void {
                    try std.testing.expectEqual(a.port(), b.port());
                    if (a.addr().as4()) |a4| {
                        const b4 = b.addr().as4().?;
                        try std.testing.expectEqualSlices(u8, &a4, &b4);
                        return;
                    }
                    const a16 = a.addr().as16().?;
                    const b16 = b.addr().as16().?;
                    try std.testing.expectEqualSlices(u8, &a16, &b16);
                }

                fn waitConnect(sock: *Net2.Runtime.Tcp) !void {
                    _ = try sock.poll(.{ .write = true, .failed = true, .hup = true, .write_interrupt = true }, 1000);
                    try sock.finishConnect();
                }

                fn waitAccept(listener: *Net2.Runtime.Tcp, remote: *net.netip.AddrPort) !Net2.Runtime.Tcp {
                    while (true) {
                        return listener.accept(remote) catch |err| switch (err) {
                            error.WouldBlock => {
                                _ = try listener.poll(.{ .read = true, .read_interrupt = true }, 1000);
                                continue;
                            },
                            else => return err,
                        };
                    }
                }

                fn sendAll(sock: *Net2.Runtime.Tcp, buf: []const u8) !void {
                    var off: usize = 0;
                    while (off < buf.len) {
                        const n = sock.send(buf[off..]) catch |err| switch (err) {
                            error.WouldBlock => {
                                _ = try sock.poll(.{ .write = true, .write_interrupt = true }, 1000);
                                continue;
                            },
                            else => return err,
                        };
                        off += n;
                    }
                }

                fn recvExact(sock: *Net2.Runtime.Tcp, buf: []u8) !void {
                    var off: usize = 0;
                    while (off < buf.len) {
                        const n = sock.recv(buf[off..]) catch |err| switch (err) {
                            error.WouldBlock => {
                                _ = try sock.poll(.{ .read = true, .read_interrupt = true, .hup = true }, 1000);
                                continue;
                            },
                            else => return err,
                        };
                        if (n == 0) return error.UnexpectedEof;
                        off += n;
                    }
                }

                fn call() !void {
                    const Runtime = Net2.Runtime;

                    var listener = try Runtime.tcp(.inet);
                    defer listener.close();

                    try listener.setOpt(.{ .socket = .{ .reuse_addr = true } });
                    try listener.bind(net.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    try listener.listen(8);

                    const listen_addr = try listener.localAddr();
                    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &listen_addr.addr().as4().?);
                    try std.testing.expect(listen_addr.port() != 0);

                    var client = try Runtime.tcp(.inet);
                    defer client.close();

                    try client.connect(listen_addr);
                    try waitConnect(&client);

                    const client_local = try client.localAddr();
                    const client_remote = try client.remoteAddr();
                    try expectAddrEq(client_remote, listen_addr);

                    var accepted_remote: net.netip.AddrPort = undefined;
                    var server = try waitAccept(&listener, &accepted_remote);
                    defer server.close();

                    try expectAddrEq(accepted_remote, client_local);
                    try expectAddrEq(try server.localAddr(), listen_addr);
                    try expectAddrEq(try server.remoteAddr(), client_local);

                    const request = "hello runtime tcp";
                    try sendAll(&client, request);

                    var req_buf: [request.len]u8 = undefined;
                    try recvExact(&server, &req_buf);
                    try std.testing.expectEqualStrings(request, &req_buf);

                    const response = "pong runtime tcp";
                    try sendAll(&server, response);

                    var resp_buf: [response.len]u8 = undefined;
                    try recvExact(&client, &resp_buf);
                    try std.testing.expectEqualStrings(response, &resp_buf);
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
