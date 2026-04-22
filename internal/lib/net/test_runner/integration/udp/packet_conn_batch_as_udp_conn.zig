const stdz = @import("stdz");
const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
const sockaddr_mod = @import("../../../fd/SockAddr.zig");
const test_utils = @import("../tcp/test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Net = net_mod.make(lib);
                    const SockAddr = sockaddr_mod.SockAddr(lib);

                    var server_pc = try Net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer server_pc.deinit();

                    var client_pc = try Net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer client_pc.deinit();

                    const server_udp = try server_pc.as(Net.UdpConn);
                    const client_udp = try client_pc.as(Net.UdpConn);
                    const server_addr = try server_udp.localAddr();
                    const client_addr = try client_udp.localAddr();

                    const encoded_server = try SockAddr.encode(server_addr);
                    const encoded_client = try SockAddr.encode(client_addr);

                    var send_a_storage: [5]u8 = undefined;
                    var send_b_storage: [5]u8 = undefined;
                    var send_batch = [_]Net.UdpConn.BatchItem{
                        .{
                            .buf = send_a_storage[0..],
                            .addr_len = @intCast(encoded_server.len),
                        },
                        .{
                            .buf = send_b_storage[0..],
                            .addr_len = @intCast(encoded_server.len),
                        },
                    };
                    @memcpy(send_batch[0].buf[0..5], "alpha");
                    send_batch[0].len = 5;
                    @memcpy(send_batch[1].buf[0..5], "bravo");
                    send_batch[1].len = 5;
                    copySockAddr(&send_batch[0].addr, &encoded_server.storage, send_batch[0].addr_len);
                    copySockAddr(&send_batch[1].addr, &encoded_server.storage, send_batch[1].addr_len);

                    try lib.testing.expectEqual(@as(usize, 2), try client_udp.sendBatch(send_batch[0..]));

                    var recv_a_storage: [64]u8 = undefined;
                    var recv_b_storage: [64]u8 = undefined;
                    var recv_batch = [_]Net.UdpConn.BatchItem{
                        .{ .buf = recv_a_storage[0..] },
                        .{ .buf = recv_b_storage[0..] },
                    };
                    try lib.testing.expectEqual(@as(usize, 2), try server_udp.recvBatch(recv_batch[0..], 100));
                    try lib.testing.expectEqualStrings("alpha", recv_batch[0].buf[0..recv_batch[0].len]);
                    try lib.testing.expectEqualStrings("bravo", recv_batch[1].buf[0..recv_batch[1].len]);
                    try expectAddrEq(&recv_batch[0], client_addr);
                    try expectAddrEq(&recv_batch[1], client_addr);

                    var invalid_send_a_storage: [5]u8 = undefined;
                    var invalid_send_b_storage: [5]u8 = undefined;
                    var invalid_send = [_]Net.UdpConn.BatchItem{
                        .{
                            .buf = invalid_send_a_storage[0..],
                            .addr_len = @intCast(encoded_server.len),
                        },
                        .{
                            .buf = invalid_send_b_storage[0..],
                            .addr_len = @intCast(encoded_server.len),
                        },
                    };
                    @memcpy(invalid_send[0].buf[0..5], "delta");
                    invalid_send[0].len = 5;
                    @memcpy(invalid_send[1].buf[0..5], "error");
                    invalid_send[1].len = invalid_send[1].buf.len + 1;
                    copySockAddr(&invalid_send[0].addr, &encoded_server.storage, invalid_send[0].addr_len);
                    copySockAddr(&invalid_send[1].addr, &encoded_server.storage, invalid_send[1].addr_len);
                    try lib.testing.expectError(error.InvalidBatchItem, client_udp.sendBatch(invalid_send[0..]));

                    var no_packet_storage: [32]u8 = undefined;
                    var no_packet_batch = [_]Net.UdpConn.BatchItem{
                        .{ .buf = no_packet_storage[0..] },
                    };
                    try lib.testing.expectError(error.TimedOut, server_udp.recvBatch(no_packet_batch[0..], 10));

                    var queued_storage: [4]u8 = undefined;
                    var queued_send = [_]Net.UdpConn.BatchItem{
                        .{
                            .buf = queued_storage[0..],
                            .addr_len = @intCast(encoded_server.len),
                        },
                    };
                    @memcpy(queued_send[0].buf[0..4], "hold");
                    queued_send[0].len = 4;
                    copySockAddr(&queued_send[0].addr, &encoded_server.storage, queued_send[0].addr_len);
                    try lib.testing.expectEqual(@as(usize, 1), try client_udp.sendBatch(queued_send[0..]));

                    var valid_recv_storage: [32]u8 = undefined;
                    var invalid_recv_storage: [0]u8 = .{};
                    var invalid_recv = [_]Net.UdpConn.BatchItem{
                        .{ .buf = valid_recv_storage[0..] },
                        .{ .buf = invalid_recv_storage[0..] },
                    };
                    try lib.testing.expectError(error.InvalidBatchItem, server_udp.recvBatch(invalid_recv[0..], 10));

                    var queued_recv_storage: [32]u8 = undefined;
                    var queued_recv = [_]Net.UdpConn.BatchItem{
                        .{ .buf = queued_recv_storage[0..] },
                    };
                    try lib.testing.expectEqual(@as(usize, 1), try server_udp.recvBatch(queued_recv[0..], 50));
                    try lib.testing.expectEqualStrings("hold", queued_recv[0].buf[0..queued_recv[0].len]);
                    try expectAddrEq(&queued_recv[0], client_addr);

                    var single_storage: [4]u8 = undefined;
                    var single_send = [_]Net.UdpConn.BatchItem{
                        .{
                            .buf = single_storage[0..],
                            .addr_len = @intCast(encoded_server.len),
                        },
                    };
                    @memcpy(single_send[0].buf[0..4], "once");
                    single_send[0].len = 4;
                    copySockAddr(&single_send[0].addr, &encoded_server.storage, single_send[0].addr_len);
                    try lib.testing.expectEqual(@as(usize, 1), try client_udp.sendBatch(single_send[0..]));

                    var partial_a_storage: [32]u8 = undefined;
                    var partial_b_storage: [32]u8 = undefined;
                    var partial_batch = [_]Net.UdpConn.BatchItem{
                        .{ .buf = partial_a_storage[0..] },
                        .{ .buf = partial_b_storage[0..] },
                    };
                    try lib.testing.expectEqual(@as(usize, 1), try server_udp.recvBatch(partial_batch[0..], 50));
                    try lib.testing.expectEqualStrings("once", partial_batch[0].buf[0..partial_batch[0].len]);
                    try lib.testing.expectEqual(@as(usize, 0), partial_batch[1].len);
                    try lib.testing.expectEqual(@as(u32, 0), partial_batch[1].addr_len);

                    server_udp.close();
                    try lib.testing.expectError(error.Closed, server_udp.localAddr());
                    try lib.testing.expectError(error.Closed, server_udp.boundPort());
                    try lib.testing.expectError(error.Closed, server_udp.boundPort6());

                    var closed_recv_storage: [8]u8 = undefined;
                    var closed_recv_batch = [_]Net.UdpConn.BatchItem{
                        .{ .buf = closed_recv_storage[0..] },
                    };
                    try lib.testing.expectError(error.Closed, server_udp.recvBatch(closed_recv_batch[0..], 0));

                    var reply_storage: [3]u8 = undefined;
                    var reply_batch = [_]Net.UdpConn.BatchItem{
                        .{
                            .buf = reply_storage[0..],
                            .addr_len = @intCast(encoded_client.len),
                        },
                    };
                    @memcpy(reply_batch[0].buf[0..3], "ack");
                    reply_batch[0].len = 3;
                    copySockAddr(&reply_batch[0].addr, &encoded_client.storage, reply_batch[0].addr_len);
                    try lib.testing.expectError(error.Closed, server_udp.sendBatch(reply_batch[0..]));
                }

                fn copySockAddr(dst: *net_mod.PacketConn.AddrStorage, src: *const lib.posix.sockaddr.storage, len: u32) void {
                    const dst_bytes: [*]u8 = @ptrCast(dst);
                    const src_bytes: [*]const u8 = @ptrCast(src);
                    for (0..@min(@as(usize, len), @sizeOf(net_mod.PacketConn.AddrStorage))) |i| {
                        dst_bytes[i] = src_bytes[i];
                    }
                }

                fn expectAddrEq(item: *const net_mod.make(lib).UdpConn.BatchItem, expected: net_mod.netip.AddrPort) !void {
                    const actual = try net_mod.make(lib).UdpConn.decodeAddrStorage(item.addr, item.addr_len);
                    try lib.testing.expectEqual(expected.port(), actual.port());
                    try lib.testing.expect(net_mod.netip.Addr.compare(expected.addr(), actual.addr()) == .eq);
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
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
