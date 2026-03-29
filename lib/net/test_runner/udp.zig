//! UDP test runner — integration tests for net.make(lib) UDP path.
//!
//! Tests listenPacket (PacketConn), connected UDP (Conn), and as() downcast.
//!
//! Usage:
//!   const runner = @import("net/test_runner/udp.zig").make(lib);
//!   t.run("net/udp", runner);

const context_mod = @import("context");
const embed = @import("embed");
const net = @import("../../net.zig");
const fd_mod = @import("../fd.zig");
const sockaddr_mod = @import("../fd/SockAddr.zig");
const testing_api = @import("testing");
const PacketConn = net.PacketConn;
const Conn = net.Conn;

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            runImpl(lib, t, allocator) catch |err| {
                t.logErrorf("udp runner failed: {}", .{err});
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}

fn runImpl(comptime lib: type, t: *testing_api.T, alloc: lib.mem.Allocator) !void {
    _ = t;
    const Net = net.make(lib);
    const Addr = net.netip.AddrPort;
    const IpAddr = net.netip.Addr;
    const SockAddr = sockaddr_mod.SockAddr(lib);
    const testing = struct {
        pub var allocator: lib.mem.Allocator = undefined;
        pub const expect = lib.testing.expect;
        pub const expectEqual = lib.testing.expectEqual;
        pub const expectEqualStrings = lib.testing.expectEqualStrings;
        pub const expectError = lib.testing.expectError;
    };
    testing.allocator = alloc;

    const Runner = struct {
        fn addr4(port: u16) Addr {
            return Addr.from4(.{ 127, 0, 0, 1 }, port);
        }

        fn addr6(comptime text: []const u8, port: u16) Addr {
            return Addr.init(comptime IpAddr.parse(text) catch unreachable, port);
        }

        fn udpIpv4ListenPacket() !void {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const udp_impl = try pc.as(Net.UdpConn);
            const port = try udp_impl.boundPort();
            const dest = addr4(port);
            const dest_sockaddr = try SockAddr.encode(dest);
            _ = try pc.writeTo("hello listenPacket", @ptrCast(&dest_sockaddr.storage), dest_sockaddr.len);

            var buf: [64]u8 = undefined;
            const result = try pc.readFrom(&buf);
            try testing.expectEqualStrings("hello listenPacket", buf[0..result.bytes_read]);
        }

        fn udpIpv6ListenPacket() !void {
            const loopback = addr6("::1", 0);

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = loopback,
            });
            defer pc.deinit();

            const uc = try pc.as(Net.UdpConn);
            const port = try uc.boundPort6();
            const dest = loopback.withPort(port);
            const dest_sockaddr = try SockAddr.encode(dest);
            _ = try pc.writeTo("udp v6 listenPacket", @ptrCast(&dest_sockaddr.storage), dest_sockaddr.len);

            var buf: [64]u8 = undefined;
            const r = try pc.readFrom(&buf);
            try testing.expectEqualStrings("udp v6 listenPacket", buf[0..r.bytes_read]);
        }

        fn udpBoundPortRejectsIpv6Sockets() !void {
            const loopback = addr6("::1", 0);

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = loopback,
            });
            defer pc.deinit();

            const udp_impl = try pc.as(Net.UdpConn);
            try testing.expectError(error.AddressFamilyMismatch, udp_impl.boundPort());
        }

        fn udpBoundPort6RejectsIpv4Sockets() !void {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const udp_impl = try pc.as(Net.UdpConn);
            try testing.expectError(error.AddressFamilyMismatch, udp_impl.boundPort6());
        }

        fn udpReadTimeout() !void {
            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            pc.setReadTimeout(1);

            var buf: [64]u8 = undefined;
            const result = pc.readFrom(&buf);
            try testing.expectError(error.TimedOut, result);

            pc.setReadTimeout(null);

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();
            const dest = addr4(port);
            const dest_sockaddr = try SockAddr.encode(dest);

            _ = try pc.writeTo("after clear", @ptrCast(&dest_sockaddr.storage), dest_sockaddr.len);
            const r = try pc.readFrom(&buf);
            try testing.expectEqualStrings("after clear", buf[0..r.bytes_read]);
        }

        fn udpDialContext() !void {
            const Context = context_mod.make(lib);

            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const udp_impl = try pc.as(Net.UdpConn);
            const port = try udp_impl.boundPort();
            const dest = addr4(port);

            var d = Net.Dialer.init(testing.allocator, .{});
            var c = try d.dialContext(ctx_api.background(), .udp, dest);
            defer c.deinit();

            const msg = "hello dialContext udp";
            _ = try c.write(msg);

            var buf: [64]u8 = undefined;
            const recv = try pc.readFrom(&buf);
            try testing.expectEqualStrings(msg, buf[0..recv.bytes_read]);

            _ = try pc.writeTo("ack", @ptrCast(&recv.addr), recv.addr_len);
            const ack_len = try c.read(buf[0..]);
            try testing.expectEqualStrings("ack", buf[0..ack_len]);
        }

        fn udpDialContextCanceledBeforeStart() !void {
            const Context = context_mod.make(lib);

            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var cancel_ctx = try ctx_api.withCancel(ctx_api.background());
            defer cancel_ctx.deinit();
            cancel_ctx.cancel();

            var d = Net.Dialer.init(testing.allocator, .{});
            try testing.expectError(
                error.Canceled,
                d.dialContext(cancel_ctx, .udp, addr4(1)),
            );
        }

        fn udpDialContextDeadlineExceededBeforeStart() !void {
            const Context = context_mod.make(lib);

            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var deadline_ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() - 1 * lib.time.ns_per_ms);
            defer deadline_ctx.deinit();

            var d = Net.Dialer.init(testing.allocator, .{});
            try testing.expectError(
                error.DeadlineExceeded,
                d.dialContext(deadline_ctx, .udp, addr4(1)),
            );
        }

        fn udpPacketConnAsDowncast() !void {
            const TcpConnType = @import("../TcpConn.zig").TcpConn(lib);

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const udp_impl = try pc.as(Net.UdpConn);
            try testing.expect(!udp_impl.closed);
            try testing.expect(udp_impl.fd != 0);

            try testing.expectError(error.TypeMismatch, pc.as(TcpConnType));
        }

        fn udpConnAsDowncast() !void {
            const posix = lib.posix;
            const TcpConnType = @import("../TcpConn.zig").TcpConn(lib);

            const fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            errdefer posix.close(fd);
            const bind_addr = addr4(0);
            const bind_sockaddr = try SockAddr.encode(bind_addr);
            try posix.bind(fd, @ptrCast(&bind_sockaddr.storage), bind_sockaddr.len);

            var c = try Net.UdpConn.init(testing.allocator, fd);
            defer c.deinit();

            const udp_impl = try c.as(Net.UdpConn);
            try testing.expect(!udp_impl.closed);

            try testing.expectError(error.TypeMismatch, c.as(TcpConnType));
        }
    };

    try Runner.udpIpv4ListenPacket();
    try Runner.udpIpv6ListenPacket();
    try Runner.udpBoundPortRejectsIpv6Sockets();
    try Runner.udpBoundPort6RejectsIpv4Sockets();
    try Runner.udpReadTimeout();
    try Runner.udpDialContext();
    try Runner.udpDialContextCanceledBeforeStart();
    try Runner.udpDialContextDeadlineExceededBeforeStart();
    try Runner.udpPacketConnAsDowncast();
    try Runner.udpConnAsDowncast();
}
