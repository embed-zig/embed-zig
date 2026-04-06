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
        const nonblock_flag: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");

        pub const InitError = Stream.InitError || SockAddr.EncodeError || posix.BindError || posix.SetSockOptError;
        pub const ListenError = error{Closed} || posix.ListenError;
        pub const AcceptError = error{ Closed, SocketNotListening } || posix.AcceptError || posix.PollError || Stream.AdoptError;
        pub const PortError = error{ Closed, Unexpected } || posix.GetSockNameError;

        pub fn init(address: Addr, reuse_addr: bool) InitError!Self {
            const encoded = try SockAddr.encode(address);
            const fd = try posix.socket(encoded.family, posix.SOCK.STREAM, 0);
            errdefer posix.close(fd);
            try setNonBlocking(fd);

            if (reuse_addr) {
                const enable: [4]u8 = @bitCast(@as(i32, 1));
                try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enable);
            }

            try posix.bind(fd, @ptrCast(&encoded.storage), encoded.len);
            return .{ .fd = fd };
        }

        pub fn deinit(self: *Self) void {
            self.closed = true;
            posix.close(self.fd);
        }

        pub fn close(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
        }

        pub fn listen(self: *Self, backlog: u31) ListenError!void {
            if (self.closed) return error.Closed;
            if (self.listening) return;
            try posix.listen(self.fd, backlog);
            self.listening = true;
        }

        pub fn accept(self: *Self) AcceptError!Stream {
            if (self.closed) return error.Closed;
            if (!self.listening) return error.SocketNotListening;

            while (true) {
                if (self.closed) return error.Closed;

                var client_addr: posix.sockaddr.storage = undefined;
                var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
                const client_fd = posix.accept(self.fd, @ptrCast(&client_addr), &client_len, 0) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.waitForAccept();
                        continue;
                    },
                    else => return err,
                };
                errdefer posix.close(client_fd);
                return try Stream.adopt(client_fd);
            }
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

        fn waitForAccept(self: *Self) (error{Closed, SocketNotListening} || posix.PollError)!void {
            if (self.closed) return error.Closed;
            if (!self.listening) return error.SocketNotListening;

            var poll_fds = [_]posix.pollfd{.{
                .fd = self.fd,
                .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR,
                .revents = 0,
            }};

            while (true) {
                if (self.closed) return error.Closed;
                if (!self.listening) return error.SocketNotListening;

                poll_fds[0].revents = 0;
                const ready = posix.poll(poll_fds[0..], 50) catch |err| {
                    if (errorNameEquals(err, "Interrupted")) continue;
                    return err;
                };
                if (ready == 0) continue;
                return;
            }
        }

        fn setNonBlocking(fd: posix.socket_t) posix.FcntlError!void {
            const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
            if ((flags & nonblock_flag) != 0) return;
            _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock_flag);
        }

        fn errorNameEquals(err: anyerror, comptime expected: []const u8) bool {
            const name = @errorName(err);
            if (name.len != expected.len) return false;
            inline for (expected, 0..) |byte, i| {
                if (name[i] != byte) return false;
            }
            return true;
        }
    };
}
