//! UdpConn — PacketConn implementation over a UDP socket fd.
//!
//! Internal type used by net.listenPacket and Resolver.
//! Users interact with the type-erased PacketConn interface,
//! or use UdpConn directly for typed access.

const Conn = @import("Conn.zig");
const PacketConn = @import("PacketConn.zig");

pub fn UdpConn(comptime lib: type) type {
    const posix = lib.posix;
    const Allocator = lib.mem.Allocator;

    return struct {
        fd: posix.socket_t,
        allocator: ?Allocator = null,
        closed: bool = false,

        const Self = @This();

        pub fn init(fd: posix.socket_t) Self {
            return .{ .fd = fd };
        }

        /// Read from a connected UDP socket (after connect()).
        pub fn read(self: *Self, buf: []u8) Conn.ReadError!usize {
            if (self.closed) return error.EndOfStream;
            return posix.recv(self.fd, buf, 0) catch |err| return switch (err) {
                error.WouldBlock => error.TimedOut,
                error.ConnectionRefused => error.ConnectionRefused,
                error.ConnectionResetByPeer => error.ConnectionReset,
                else => error.Unexpected,
            };
        }

        /// Write to a connected UDP socket (after connect()).
        pub fn write(self: *Self, buf: []const u8) Conn.WriteError!usize {
            if (self.closed) return error.BrokenPipe;
            return posix.send(self.fd, buf, 0) catch |err| return switch (err) {
                error.WouldBlock => error.TimedOut,
                error.ConnectionResetByPeer => error.ConnectionReset,
                error.BrokenPipe => error.BrokenPipe,
                else => error.Unexpected,
            };
        }

        /// Connect to a remote address (makes read/write usable without address).
        pub fn connectTo(self: *Self, addr: [*]const u8, addr_len: u32) !void {
            try posix.connect(self.fd, @ptrCast(addr), addr_len);
        }

        pub fn conn(self: *Self) Conn {
            return Conn.init(self);
        }

        pub fn readFrom(self: *Self, buf: []u8) PacketConn.ReadFromError!PacketConn.ReadFromResult {
            if (self.closed) return error.Unexpected;
            var result: PacketConn.ReadFromResult = .{
                .bytes_read = 0,
                .addr = @splat(0),
                .addr_len = @sizeOf(PacketConn.AddrStorage),
            };
            const n = posix.recvfrom(
                self.fd,
                buf,
                0,
                @ptrCast(&result.addr),
                @ptrCast(&result.addr_len),
            ) catch |err| return switch (err) {
                error.WouldBlock => error.TimedOut,
                error.ConnectionRefused => error.ConnectionRefused,
                else => error.Unexpected,
            };
            result.bytes_read = n;
            return result;
        }

        pub fn writeTo(self: *Self, buf: []const u8, addr: [*]const u8, addr_len: u32) PacketConn.WriteToError!usize {
            if (self.closed) return error.Unexpected;
            return posix.sendto(
                self.fd,
                buf,
                0,
                @ptrCast(addr),
                addr_len,
            ) catch |err| return switch (err) {
                error.MessageTooBig => error.MessageTooLong,
                error.NetworkUnreachable => error.NetworkUnreachable,
                error.AccessDenied => error.AccessDenied,
                else => error.Unexpected,
            };
        }

        pub fn close(self: *Self) void {
            if (!self.closed) {
                posix.close(self.fd);
                self.closed = true;
            }
        }

        pub fn deinit(self: *Self) void {
            self.close();
            if (self.allocator) |a| a.destroy(self);
        }

        pub fn setReadTimeout(self: *Self, ms: ?u32) void {
            setSocketTimeout(self.fd, posix.SO.RCVTIMEO, ms);
        }

        pub fn setWriteTimeout(self: *Self, ms: ?u32) void {
            setSocketTimeout(self.fd, posix.SO.SNDTIMEO, ms);
        }

        fn setSocketTimeout(fd: posix.socket_t, optname: u32, ms: ?u32) void {
            const tv: posix.timeval = if (ms) |t| .{
                .sec = @intCast(t / 1000),
                .usec = @intCast((t % 1000) * 1000),
            } else .{ .sec = 0, .usec = 0 };
            const bytes: [@sizeOf(posix.timeval)]u8 = @bitCast(tv);
            posix.setsockopt(fd, posix.SOL.SOCKET, optname, &bytes) catch {};
        }

        pub fn packetConn(self: *Self) PacketConn {
            return PacketConn.init(self);
        }
    };
}
