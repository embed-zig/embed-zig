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
const fd_mod = @import("fd.zig");
const netip = @import("netip.zig");

pub fn UdpConn(comptime lib: type) type {
    const posix = lib.posix;
    const Allocator = lib.mem.Allocator;
    const AddrPort = netip.AddrPort;
    const Packet = fd_mod.Packet(lib);

    return struct {
        fd: posix.socket_t,
        packet: Packet,
        allocator: Allocator,
        closed: bool = false,
        read_timeout_ms: ?u32 = null,
        write_timeout_ms: ?u32 = null,

        const Self = @This();

        pub fn read(self: *Self, buf: []u8) Conn.ReadError!usize {
            if (self.closed) return error.EndOfStream;
            if (buf.len == 0) return 0;
            self.applyReadTimeout();
            return self.packet.read(buf) catch |err| return switch (err) {
                error.Closed => error.EndOfStream,
                error.TimedOut => error.TimedOut,
                error.ConnectionRefused => error.ConnectionRefused,
                error.ConnectionResetByPeer => error.ConnectionReset,
                else => error.Unexpected,
            };
        }

        pub fn write(self: *Self, buf: []const u8) Conn.WriteError!usize {
            if (self.closed) return error.BrokenPipe;
            self.applyWriteTimeout();
            return self.packet.write(buf) catch |err| return switch (err) {
                error.Closed => error.BrokenPipe,
                error.TimedOut => error.TimedOut,
                error.ConnectionRefused => error.ConnectionRefused,
                error.ConnectionResetByPeer => error.ConnectionReset,
                error.BrokenPipe => error.BrokenPipe,
                else => error.Unexpected,
            };
        }

        pub fn readFrom(self: *Self, buf: []u8) PacketConn.ReadFromError!PacketConn.ReadFromResult {
            if (self.closed) return error.Closed;
            if (buf.len == 0) return .{
                .bytes_read = 0,
                .addr = @splat(0),
                .addr_len = 0,
            };
            self.applyReadTimeout();
            const packet_result = self.packet.readFrom(buf) catch |err| return switch (err) {
                error.Closed => error.Closed,
                error.TimedOut => error.TimedOut,
                error.ConnectionRefused => error.ConnectionRefused,
                error.ConnectionResetByPeer => error.ConnectionReset,
                else => error.Unexpected,
            };
            var result: PacketConn.ReadFromResult = .{
                .bytes_read = packet_result.bytes_read,
                .addr = @splat(0),
                .addr_len = @intCast(packet_result.addr_len),
            };
            copySockaddrBytes(&result.addr, &packet_result.addr, result.addr_len);
            return result;
        }

        pub fn writeTo(self: *Self, buf: []const u8, addr: [*]const u8, addr_len: u32) PacketConn.WriteToError!usize {
            if (self.closed) return error.Closed;
            self.applyWriteTimeout();
            const dest = rawSockaddrToAddr(addr, addr_len) catch return error.Unexpected;
            return self.packet.writeTo(buf, dest) catch |err| return switch (err) {
                error.Closed => error.Closed,
                error.TimedOut => error.TimedOut,
                error.MessageTooBig => error.MessageTooLong,
                error.NetworkUnreachable => error.NetworkUnreachable,
                error.AccessDenied => error.AccessDenied,
                else => error.Unexpected,
            };
        }

        pub fn close(self: *Self) void {
            if (!self.closed) {
                self.packet.close();
                self.closed = true;
            }
        }

        pub fn deinit(self: *Self) void {
            self.close();
            const a = self.allocator;
            a.destroy(self);
        }

        pub fn setReadTimeout(self: *Self, ms: ?u32) void {
            self.read_timeout_ms = ms;
        }

        pub fn setWriteTimeout(self: *Self, ms: ?u32) void {
            self.write_timeout_ms = ms;
        }

        pub fn boundPort(self: *const Self) !u16 {
            var bound: posix.sockaddr.storage = undefined;
            var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            try posix.getsockname(self.fd, @ptrCast(&bound), &bound_len);
            const family = @as(*const posix.sockaddr, @ptrCast(&bound)).family;
            if (family != posix.AF.INET) return error.AddressFamilyMismatch;
            return lib.mem.bigToNative(u16, @as(*const posix.sockaddr.in, @ptrCast(@alignCast(&bound))).port);
        }

        pub fn boundPort6(self: *const Self) !u16 {
            var bound: posix.sockaddr.storage = undefined;
            var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            try posix.getsockname(self.fd, @ptrCast(&bound), &bound_len);
            const family = @as(*const posix.sockaddr, @ptrCast(&bound)).family;
            if (family != posix.AF.INET6) return error.AddressFamilyMismatch;
            return lib.mem.bigToNative(u16, @as(*const posix.sockaddr.in6, @ptrCast(@alignCast(&bound))).port);
        }

        fn applyReadTimeout(self: *Self) void {
            self.packet.setReadDeadline(timeoutToDeadline(self.read_timeout_ms));
        }

        fn applyWriteTimeout(self: *Self) void {
            self.packet.setWriteDeadline(timeoutToDeadline(self.write_timeout_ms));
        }

        fn timeoutToDeadline(ms: ?u32) ?i64 {
            const timeout_ms = ms orelse return null;
            return lib.time.milliTimestamp() + timeout_ms;
        }

        fn copySockaddrBytes(dst: *PacketConn.AddrStorage, src: *const posix.sockaddr.storage, len: u32) void {
            const dst_bytes: [*]u8 = @ptrCast(dst);
            const src_bytes: [*]const u8 = @ptrCast(src);
            const copy_len = @min(@as(usize, len), @sizeOf(PacketConn.AddrStorage));
            for (0..copy_len) |i| dst_bytes[i] = src_bytes[i];
        }

        fn rawSockaddrToAddr(addr: [*]const u8, addr_len: u32) error{Unexpected}!AddrPort {
            if (addr_len < @sizeOf(posix.sockaddr)) return error.Unexpected;

            var storage: posix.sockaddr.storage = undefined;
            const storage_bytes: [*]u8 = @ptrCast(&storage);
            for (0..@sizeOf(posix.sockaddr.storage)) |i| storage_bytes[i] = 0;
            const copy_len = @min(@as(usize, addr_len), @sizeOf(posix.sockaddr.storage));
            for (0..copy_len) |i| storage_bytes[i] = addr[i];

            return switch (@as(*const posix.sockaddr, @ptrCast(&storage)).family) {
                posix.AF.INET => blk: {
                    if (addr_len < @sizeOf(posix.sockaddr.in)) return error.Unexpected;
                    const in: *const posix.sockaddr.in = @ptrCast(@alignCast(&storage));
                    const addr_bytes: [4]u8 = @bitCast(in.addr);
                    break :blk AddrPort.from4(addr_bytes, lib.mem.bigToNative(u16, in.port));
                },
                posix.AF.INET6 => blk: {
                    if (addr_len < @sizeOf(posix.sockaddr.in6)) return error.Unexpected;
                    const in6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(&storage));
                    var ip = netip.Addr.from16(in6.addr);
                    if (in6.scope_id != 0) {
                        var scope_buf: [10]u8 = undefined;
                        const scope = lib.fmt.bufPrint(&scope_buf, "{d}", .{in6.scope_id}) catch return error.Unexpected;
                        ip.zone_len = @intCast(scope.len);
                        @memcpy(ip.zone[0..scope.len], scope);
                    }
                    break :blk AddrPort.init(ip, lib.mem.bigToNative(u16, in6.port));
                },
                else => return error.Unexpected,
            };
        }

        pub fn initFromPacket(allocator: Allocator, packet: Packet) Allocator.Error!Conn {
            const self = try allocator.create(Self);
            self.* = .{
                .fd = packet.fd,
                .packet = packet,
                .allocator = allocator,
            };
            return Conn.init(self);
        }

        pub fn initPacketFromPacket(allocator: Allocator, packet: Packet) Allocator.Error!PacketConn {
            const self = try allocator.create(Self);
            self.* = .{
                .fd = packet.fd,
                .packet = packet,
                .allocator = allocator,
            };
            return PacketConn.init(self);
        }

        /// Connected UDP → Conn (read/write after connect).
        pub fn init(allocator: Allocator, fd: posix.socket_t) !Conn {
            const packet = try Packet.adopt(fd);
            return initFromPacket(allocator, packet);
        }

        /// Unconnected UDP → PacketConn (readFrom/writeTo).
        pub fn initPacket(allocator: Allocator, fd: posix.socket_t) !PacketConn {
            const packet = try Packet.adopt(fd);
            return initPacketFromPacket(allocator, packet);
        }
    };
}
