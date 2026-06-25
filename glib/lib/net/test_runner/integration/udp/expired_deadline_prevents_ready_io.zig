const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("../tcp/test_utils.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn expiredDeadline() @import("time").instant.Time {
                    return net.time.instant.add(net.time.instant.now(), -1 * net.time.duration.MilliSecond);
                }

                fn packetReadDeadlineRejectsQueuedDatagram(a: std.mem.Allocator) !void {
                    var pc = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer pc.deinit();

                    const port = try (try pc.as(net.UdpConn)).boundPort();
                    const dest = test_utils.addr4(.{ 127, 0, 0, 1 }, port);
                    _ = try pc.writeTo("queued", dest);

                    pc.setReadDeadline(expiredDeadline());

                    var buf: [16]u8 = undefined;
                    try std.testing.expectError(error.TimedOut, pc.readFrom(&buf));

                    pc.setReadDeadline(null);
                    const result = try pc.readFrom(&buf);
                    try std.testing.expectEqualStrings("queued", buf[0..result.bytes_read]);
                }

                fn connReadDeadlineRejectsQueuedDatagram(a: std.mem.Allocator) !void {
                    var server = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer server.deinit();

                    const server_port = try (try server.as(net.UdpConn)).boundPort();
                    var conn = try net.dial(a, .udp, test_utils.addr4(.{ 127, 0, 0, 1 }, server_port));
                    defer conn.deinit();

                    _ = try conn.write("hello");

                    var server_buf: [16]u8 = undefined;
                    const received = try server.readFrom(&server_buf);
                    try std.testing.expectEqualStrings("hello", server_buf[0..received.bytes_read]);
                    _ = try server.writeTo("queued", received.addr);

                    conn.setReadDeadline(expiredDeadline());

                    var buf: [16]u8 = undefined;
                    try std.testing.expectError(error.TimedOut, conn.read(&buf));

                    conn.setReadDeadline(null);
                    const bytes_read = try conn.read(&buf);
                    try std.testing.expectEqualStrings("queued", buf[0..bytes_read]);
                }

                fn packetWriteDeadlineRejectsReadySocket(a: std.mem.Allocator) !void {
                    var server = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer server.deinit();

                    const server_port = try (try server.as(net.UdpConn)).boundPort();
                    const dest = test_utils.addr4(.{ 127, 0, 0, 1 }, server_port);

                    var sender = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer sender.deinit();

                    sender.setWriteDeadline(expiredDeadline());
                    try std.testing.expectError(error.TimedOut, sender.writeTo("blocked", dest));

                    sender.setWriteDeadline(null);
                    _ = try sender.writeTo("sent", dest);

                    var buf: [16]u8 = undefined;
                    const result = try server.readFrom(&buf);
                    try std.testing.expectEqualStrings("sent", buf[0..result.bytes_read]);
                }

                fn connWriteDeadlineRejectsReadySocket(a: std.mem.Allocator) !void {
                    var server = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer server.deinit();

                    const server_port = try (try server.as(net.UdpConn)).boundPort();
                    var conn = try net.dial(a, .udp, test_utils.addr4(.{ 127, 0, 0, 1 }, server_port));
                    defer conn.deinit();

                    conn.setWriteDeadline(expiredDeadline());
                    try std.testing.expectError(error.TimedOut, conn.write("blocked"));

                    conn.setWriteDeadline(null);
                    _ = try conn.write("sent");

                    var buf: [16]u8 = undefined;
                    const result = try server.readFrom(&buf);
                    try std.testing.expectEqualStrings("sent", buf[0..result.bytes_read]);
                }

                fn call(a: std.mem.Allocator) !void {
                    try packetReadDeadlineRejectsQueuedDatagram(a);
                    try connReadDeadlineRejectsQueuedDatagram(a);
                    try packetWriteDeadlineRejectsReadySocket(a);
                    try connWriteDeadlineRejectsReadySocket(a);
                }
            };
            Body.call(allocator) catch |err| {
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
