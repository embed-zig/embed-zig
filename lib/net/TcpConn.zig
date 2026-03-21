//! TcpConn — constructs a Conn over a TCP socket fd (like Go's net.TCPConn).
//!
//! Returns a Conn directly. The internal state is heap-allocated and
//! freed on deinit().

const Conn = @import("Conn.zig");

pub fn TcpConn(comptime lib: type) type {
    const posix = lib.posix;
    const Allocator = lib.mem.Allocator;

    return struct {
        fd: posix.socket_t,
        allocator: Allocator,
        closed: bool = false,

        const Self = @This();

        pub fn read(self: *Self, buf: []u8) Conn.ReadError!usize {
            if (self.closed) return error.EndOfStream;
            return posix.recv(self.fd, buf, 0) catch |err| return switch (err) {
                error.WouldBlock => error.TimedOut,
                error.ConnectionResetByPeer => error.ConnectionReset,
                error.ConnectionRefused => error.ConnectionRefused,
                else => error.Unexpected,
            };
        }

        pub fn write(self: *Self, buf: []const u8) Conn.WriteError!usize {
            if (self.closed) return error.BrokenPipe;
            return posix.send(self.fd, buf, 0) catch |err| return switch (err) {
                error.WouldBlock => error.TimedOut,
                error.ConnectionResetByPeer => error.ConnectionReset,
                error.BrokenPipe => error.BrokenPipe,
                else => error.Unexpected,
            };
        }

        pub fn close(self: *Self) void {
            if (!self.closed) {
                posix.shutdown(self.fd, .both) catch {};
                posix.close(self.fd);
                self.closed = true;
            }
        }

        pub fn deinit(self: *Self) void {
            self.close();
            const a = self.allocator;
            a.destroy(self);
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

        pub fn init(allocator: Allocator, fd: posix.socket_t) Allocator.Error!Conn {
            const self = try allocator.create(Self);
            self.* = .{ .fd = fd, .allocator = allocator };
            return Conn.init(self);
        }
    };
}
