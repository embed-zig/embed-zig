//! UdpConn — constructs a Conn or PacketConn over a UDP socket fd.
//!
//! Returns Conn / PacketConn directly. The internal state is heap-allocated
//! and freed on deinit().
//!
//!   // Connected UDP → Conn (read/write after connect)
//!   var c = try UdpConn.init(allocator, fd);
//!   defer c.deinit();
//!
//!   // Unconnected UDP → PacketConn (readFrom/writeTo)
//!   var pc = try UdpConn.initPacket(allocator, fd);
//!   defer pc.deinit();

const Conn = @import("Conn.zig");
const PacketConn = @import("PacketConn.zig");

pub fn UdpConn(comptime lib: type) type {
    const posix = lib.posix;
    const Allocator = lib.mem.Allocator;

    const Impl = struct {
        fd: posix.socket_t,
        allocator: Allocator,
        closed: bool = false,

        const Self = @This();

        pub fn read(self: *Self, buf: []u8) Conn.ReadError!usize {
            if (self.closed) return error.EndOfStream;
            return posix.recv(self.fd, buf, 0) catch |err| return switch (err) {
                error.WouldBlock => error.TimedOut,
                error.ConnectionRefused => error.ConnectionRefused,
                error.ConnectionResetByPeer => error.ConnectionReset,
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

        // UDP preserves packet boundaries, so this intentionally performs a
        // single recv instead of looping like the default Conn.readAll.
        // A shorter packet is reported as ShortRead.
        // TODO: Detecting oversized datagrams portably would require extra
        // buffering/platform-specific APIs, so truncation is not distinguished
        // here in order to keep readAll allocation-free and preserve the empty
        // buffer no-op behavior of Conn.readAll.
        pub fn readAll(self: *Self, buf: []u8) Conn.ReadError!void {
            if (buf.len == 0) return;
            const n = try self.read(buf);
            if (n != buf.len) return error.ShortRead;
        }

        // UDP writeAll intentionally maps to a single send call. Looping here
        // would emit multiple datagrams, which is not the desired UDP behavior.
        pub fn writeAll(self: *Self, buf: []const u8) Conn.WriteError!void {
            const n = try self.write(buf);
            if (n != buf.len) return error.Unexpected;
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
                error.WouldBlock => error.TimedOut,
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
            const a = self.allocator;
            a.destroy(self);
        }

        pub fn setReadTimeout(self: *Self, ms: ?u32) void {
            setSocketTimeout(self.fd, posix.SO.RCVTIMEO, ms);
        }

        pub fn setWriteTimeout(self: *Self, ms: ?u32) void {
            setSocketTimeout(self.fd, posix.SO.SNDTIMEO, ms);
        }

        pub fn boundPort(self: *const Self) !u16 {
            var bound: posix.sockaddr.in = undefined;
            var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            try posix.getsockname(self.fd, @ptrCast(&bound), &bound_len);
            return lib.mem.bigToNative(u16, bound.port);
        }

        pub fn boundPort6(self: *const Self) !u16 {
            var bound: posix.sockaddr.in6 = undefined;
            var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in6);
            try posix.getsockname(self.fd, @ptrCast(&bound), &bound_len);
            return lib.mem.bigToNative(u16, bound.port);
        }

        fn setSocketTimeout(fd: posix.socket_t, optname: u32, ms: ?u32) void {
            const tv: posix.timeval = if (ms) |t| .{
                .sec = @intCast(t / 1000),
                .usec = @intCast((t % 1000) * 1000),
            } else .{ .sec = 0, .usec = 0 };
            const bytes: [@sizeOf(posix.timeval)]u8 = @bitCast(tv);
            posix.setsockopt(fd, posix.SOL.SOCKET, optname, &bytes) catch {};
        }
    };

    return struct {
        pub const Inner = Impl;

        /// Connected UDP → Conn (read/write after connect).
        pub fn init(allocator: Allocator, fd: posix.socket_t) Allocator.Error!Conn {
            const impl = try allocator.create(Impl);
            impl.* = .{ .fd = fd, .allocator = allocator };
            return Conn.init(impl);
        }

        /// Unconnected UDP → PacketConn (readFrom/writeTo).
        pub fn initPacket(allocator: Allocator, fd: posix.socket_t) Allocator.Error!PacketConn {
            const impl = try allocator.create(Impl);
            impl.* = .{ .fd = fd, .allocator = allocator };
            return PacketConn.init(impl);
        }
    };
}
