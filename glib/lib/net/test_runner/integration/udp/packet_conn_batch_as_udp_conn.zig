const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("../tcp/test_utils.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: std.mem.Allocator) !void {
                    var server_pc = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer server_pc.deinit();

                    var client_pc = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer client_pc.deinit();

                    const server_udp = try server_pc.as(net.UdpConn);
                    const client_udp = try client_pc.as(net.UdpConn);
                    const server_addr = try server_udp.localAddr();
                    const client_addr = try client_udp.localAddr();

                    var send_a_storage: [5]u8 = undefined;
                    var send_b_storage: [5]u8 = undefined;
                    var send_batch = [_]net.UdpConn.BatchItem{
                        .{
                            .buf = send_a_storage[0..],
                            .addr = server_addr,
                        },
                        .{
                            .buf = send_b_storage[0..],
                            .addr = server_addr,
                        },
                    };
                    @memcpy(send_batch[0].buf[0..5], "alpha");
                    send_batch[0].len = 5;
                    @memcpy(send_batch[1].buf[0..5], "bravo");
                    send_batch[1].len = 5;

                    try std.testing.expectEqual(@as(usize, 2), try client_udp.sendBatch(send_batch[0..]));

                    var recv_a_storage: [64]u8 = undefined;
                    var recv_b_storage: [64]u8 = undefined;
                    var recv_batch = [_]net.UdpConn.BatchItem{
                        .{ .buf = recv_a_storage[0..] },
                        .{ .buf = recv_b_storage[0..] },
                    };
                    try std.testing.expectEqual(@as(usize, 2), try server_udp.recvBatch(recv_batch[0..], 100 * net.time.duration.MilliSecond));
                    try std.testing.expectEqualStrings("alpha", recv_batch[0].buf[0..recv_batch[0].len]);
                    try std.testing.expectEqualStrings("bravo", recv_batch[1].buf[0..recv_batch[1].len]);
                    try expectAddrEq(&recv_batch[0], client_addr);
                    try expectAddrEq(&recv_batch[1], client_addr);

                    var invalid_send_a_storage: [5]u8 = undefined;
                    var invalid_send_b_storage: [5]u8 = undefined;
                    var invalid_send = [_]net.UdpConn.BatchItem{
                        .{
                            .buf = invalid_send_a_storage[0..],
                            .addr = server_addr,
                        },
                        .{
                            .buf = invalid_send_b_storage[0..],
                            .addr = server_addr,
                        },
                    };
                    @memcpy(invalid_send[0].buf[0..5], "delta");
                    invalid_send[0].len = 5;
                    @memcpy(invalid_send[1].buf[0..5], "error");
                    invalid_send[1].len = invalid_send[1].buf.len + 1;
                    try std.testing.expectError(error.InvalidBatchItem, client_udp.sendBatch(invalid_send[0..]));

                    var missing_addr_storage: [4]u8 = undefined;
                    var missing_addr_send = [_]net.UdpConn.BatchItem{
                        .{ .buf = missing_addr_storage[0..] },
                    };
                    @memcpy(missing_addr_send[0].buf[0..4], "miss");
                    missing_addr_send[0].len = 4;
                    try std.testing.expectError(error.InvalidBatchItem, client_udp.sendBatch(missing_addr_send[0..]));

                    var no_packet_storage: [32]u8 = undefined;
                    var no_packet_batch = [_]net.UdpConn.BatchItem{
                        .{ .buf = no_packet_storage[0..] },
                    };
                    try std.testing.expectError(error.TimedOut, server_udp.recvBatch(no_packet_batch[0..], 10 * net.time.duration.MilliSecond));

                    var queued_storage: [4]u8 = undefined;
                    var queued_send = [_]net.UdpConn.BatchItem{
                        .{
                            .buf = queued_storage[0..],
                            .addr = server_addr,
                        },
                    };
                    @memcpy(queued_send[0].buf[0..4], "hold");
                    queued_send[0].len = 4;
                    try std.testing.expectEqual(@as(usize, 1), try client_udp.sendBatch(queued_send[0..]));

                    var valid_recv_storage: [32]u8 = undefined;
                    var invalid_recv_storage: [0]u8 = .{};
                    var invalid_recv = [_]net.UdpConn.BatchItem{
                        .{ .buf = valid_recv_storage[0..] },
                        .{ .buf = invalid_recv_storage[0..] },
                    };
                    try std.testing.expectError(error.InvalidBatchItem, server_udp.recvBatch(invalid_recv[0..], 10 * net.time.duration.MilliSecond));

                    var queued_recv_storage: [32]u8 = undefined;
                    var queued_recv = [_]net.UdpConn.BatchItem{
                        .{ .buf = queued_recv_storage[0..] },
                    };
                    try std.testing.expectEqual(@as(usize, 1), try server_udp.recvBatch(queued_recv[0..], 50 * net.time.duration.MilliSecond));
                    try std.testing.expectEqualStrings("hold", queued_recv[0].buf[0..queued_recv[0].len]);
                    try expectAddrEq(&queued_recv[0], client_addr);

                    var single_storage: [4]u8 = undefined;
                    var single_send = [_]net.UdpConn.BatchItem{
                        .{
                            .buf = single_storage[0..],
                            .addr = server_addr,
                        },
                    };
                    @memcpy(single_send[0].buf[0..4], "once");
                    single_send[0].len = 4;
                    try std.testing.expectEqual(@as(usize, 1), try client_udp.sendBatch(single_send[0..]));

                    var partial_a_storage: [32]u8 = undefined;
                    var partial_b_storage: [32]u8 = undefined;
                    var partial_batch = [_]net.UdpConn.BatchItem{
                        .{ .buf = partial_a_storage[0..] },
                        .{ .buf = partial_b_storage[0..] },
                    };
                    try std.testing.expectEqual(@as(usize, 1), try server_udp.recvBatch(partial_batch[0..], 50 * net.time.duration.MilliSecond));
                    try std.testing.expectEqualStrings("once", partial_batch[0].buf[0..partial_batch[0].len]);
                    try std.testing.expectEqual(@as(usize, 0), partial_batch[1].len);
                    try std.testing.expect(!partial_batch[1].addr.isValid());

                    server_udp.close();
                    try std.testing.expectError(error.Closed, server_udp.localAddr());
                    try std.testing.expectError(error.Closed, server_udp.boundPort());
                    try std.testing.expectError(error.Closed, server_udp.boundPort6());

                    var closed_recv_storage: [8]u8 = undefined;
                    var closed_recv_batch = [_]net.UdpConn.BatchItem{
                        .{ .buf = closed_recv_storage[0..] },
                    };
                    try std.testing.expectError(error.Closed, server_udp.recvBatch(closed_recv_batch[0..], 0 * net.time.duration.MilliSecond));

                    var reply_storage: [3]u8 = undefined;
                    var reply_batch = [_]net.UdpConn.BatchItem{
                        .{
                            .buf = reply_storage[0..],
                            .addr = client_addr,
                        },
                    };
                    @memcpy(reply_batch[0].buf[0..3], "ack");
                    reply_batch[0].len = 3;
                    try std.testing.expectError(error.Closed, server_udp.sendBatch(reply_batch[0..]));
                }

                fn expectAddrEq(item: *const net.UdpConn.BatchItem, expected: net.netip.AddrPort) !void {
                    const actual = item.addr;
                    try std.testing.expectEqual(expected.port(), actual.port());
                    try std.testing.expect(net.netip.Addr.compare(expected.addr(), actual.addr()) == .eq);
                }
            };
            Body.call(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            std.testing.allocator.destroy(self);
        }
    };

    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
