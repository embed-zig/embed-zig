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

                fn sendToWait(sock: *net.Runtime.Udp, buf: []const u8, dst: net.netip.AddrPort) !usize {
                    while (true) {
                        return sock.sendTo(buf, dst) catch |err| switch (err) {
                            error.WouldBlock => {
                                _ = try sock.poll(.{ .write = true, .write_interrupt = true }, @intCast(1000 * net.time.duration.MilliSecond));
                                continue;
                            },
                            else => return err,
                        };
                    }
                }

                fn recvFromWait(sock: *net.Runtime.Udp, buf: []u8, src: *net.netip.AddrPort) !usize {
                    while (true) {
                        return sock.recvFrom(buf, src) catch |err| switch (err) {
                            error.WouldBlock => {
                                _ = try sock.poll(.{ .read = true, .read_interrupt = true }, @intCast(1000 * net.time.duration.MilliSecond));
                                continue;
                            },
                            else => return err,
                        };
                    }
                }

                fn call() !void {
                    const Runtime = net.Runtime;

                    var server = try Runtime.udp(.inet);
                    defer {
                        server.close();
                        server.deinit();
                    }

                    try server.setOpt(.{ .socket = .{ .reuse_addr = true } });
                    try server.bind(net.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 0));

                    const server_addr = try server.localAddr();
                    try host_std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &server_addr.addr().as4().?);
                    try host_std.testing.expect(server_addr.port() != 0);

                    var client = try Runtime.udp(.inet);
                    defer {
                        client.close();
                        client.deinit();
                    }

                    try client.setOpt(.{ .socket = .{ .reuse_addr = true } });
                    try client.bind(net.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    const client_addr = try client.localAddr();

                    const request = "hello runtime udp";
                    const req_sent = try sendToWait(&client, request, server_addr);
                    try host_std.testing.expectEqual(request.len, req_sent);

                    var from: net.netip.AddrPort = undefined;
                    var req_buf: [request.len]u8 = undefined;
                    const req_recv = try recvFromWait(&server, &req_buf, &from);
                    try host_std.testing.expectEqual(request.len, req_recv);
                    try host_std.testing.expectEqualStrings(request, &req_buf);
                    try expectAddrEq(from, client_addr);

                    const response = "pong runtime udp";
                    const resp_sent = try sendToWait(&server, response, from);
                    try host_std.testing.expectEqual(response.len, resp_sent);

                    var reply_from: net.netip.AddrPort = undefined;
                    var resp_buf: [response.len]u8 = undefined;
                    const resp_recv = try recvFromWait(&client, &resp_buf, &reply_from);
                    try host_std.testing.expectEqual(response.len, resp_recv);
                    try host_std.testing.expectEqualStrings(response, &resp_buf);
                    try expectAddrEq(reply_from, server_addr);
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
