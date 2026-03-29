const sockaddr_mod = @import("SockAddr.zig");
const stream_mod = @import("Stream.zig");

pub fn Listener(comptime lib: type) type {
    const posix = lib.posix;
    const Addr = @import("../netip/AddrPort.zig");
    const SockAddr = sockaddr_mod.SockAddr(lib);
    const Stream = stream_mod.Stream(lib);

    return struct {
        fd: posix.socket_t,
        closed: bool = false,
        listening: bool = false,

        const Self = @This();

        pub const InitError = Stream.InitError || SockAddr.EncodeError || posix.BindError || posix.SetSockOptError;
        pub const ListenError = error{Closed} || posix.ListenError;
        pub const AcceptError = error{ Closed, SocketNotListening } || posix.AcceptError || Stream.AdoptError;
        pub const PortError = error{ Closed, Unexpected } || posix.GetSockNameError;

        pub fn init(address: Addr, reuse_addr: bool) InitError!Self {
            const encoded = try SockAddr.encode(address);
            const fd = try posix.socket(encoded.family, posix.SOCK.STREAM, 0);
            errdefer posix.close(fd);

            if (reuse_addr) {
                const enable: [4]u8 = @bitCast(@as(i32, 1));
                try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enable);
            }

            try posix.bind(fd, @ptrCast(&encoded.storage), encoded.len);
            return .{ .fd = fd };
        }

        pub fn deinit(self: *Self) void {
            self.close();
        }

        pub fn close(self: *Self) void {
            if (self.closed) return;
            posix.close(self.fd);
            self.closed = true;
        }

        pub fn listen(self: *Self, backlog: u31) ListenError!void {
            if (self.closed) return error.Closed;
            if (self.listening) return;
            try posix.listen(self.fd, backlog);
            self.listening = true;
        }

        pub fn accept(self: *Self) AcceptError!Stream {
            if (self.closed or !self.listening) return error.SocketNotListening;

            var client_addr: posix.sockaddr.storage = undefined;
            var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            const client_fd = try posix.accept(self.fd, @ptrCast(&client_addr), &client_len, 0);
            errdefer posix.close(client_fd);
            return try Stream.adopt(client_fd);
        }

        pub fn port(self: *Self) PortError!u16 {
            if (self.closed) return error.Closed;

            var bound: posix.sockaddr.storage = undefined;
            var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            try posix.getsockname(self.fd, @ptrCast(&bound), &bound_len);

            const family = @as(*const posix.sockaddr, @ptrCast(&bound)).family;
            return switch (family) {
                posix.AF.INET => lib.mem.bigToNative(u16, @as(*const posix.sockaddr.in, @ptrCast(@alignCast(&bound))).port),
                posix.AF.INET6 => lib.mem.bigToNative(u16, @as(*const posix.sockaddr.in6, @ptrCast(@alignCast(&bound))).port),
                else => error.Unexpected,
            };
        }
    };
}
