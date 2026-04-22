pub fn make(comptime lib: type) type {
    const posix = lib.posix;

    return struct {
        recv_fd: posix.socket_t,
        send_fd: posix.socket_t,

        const Self = @This();
        const loopback_addr = [4]u8{ 127, 0, 0, 1 };
        const loopback_addr_u32 = @as(*align(1) const u32, @ptrCast(&loopback_addr)).*;
        const nonblock_flag: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");

        pub const InitError =
            posix.SocketError ||
            posix.BindError ||
            posix.GetSockNameError ||
            posix.ConnectError ||
            posix.FcntlError;

        pub fn init() InitError!Self {
            const recv_fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            errdefer posix.close(recv_fd);

            try setNonBlocking(recv_fd);

            var recv_storage: posix.sockaddr.storage = undefined;
            zeroStorage(&recv_storage);
            const recv_addr: *posix.sockaddr.in = @ptrCast(@alignCast(&recv_storage));
            recv_addr.* = .{
                .port = 0,
                .addr = loopback_addr_u32,
            };
            try posix.bind(recv_fd, @ptrCast(&recv_storage), @sizeOf(posix.sockaddr.in));

            var bound_addr: posix.sockaddr.in = undefined;
            var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            try posix.getsockname(recv_fd, @ptrCast(&bound_addr), &bound_len);

            const send_fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            errdefer posix.close(send_fd);

            try setNonBlocking(send_fd);

            var send_storage: posix.sockaddr.storage = undefined;
            zeroStorage(&send_storage);
            const send_addr: *posix.sockaddr.in = @ptrCast(@alignCast(&send_storage));
            send_addr.* = .{
                .port = bound_addr.port,
                .addr = loopback_addr_u32,
            };
            try posix.connect(send_fd, @ptrCast(&send_storage), @sizeOf(posix.sockaddr.in));

            return .{
                .recv_fd = recv_fd,
                .send_fd = send_fd,
            };
        }

        pub fn deinit(self: *Self) void {
            posix.close(self.send_fd);
            posix.close(self.recv_fd);
            self.* = undefined;
        }

        pub fn signal(self: *const Self) void {
            const wake_byte = [_]u8{0};
            _ = posix.send(self.send_fd, wake_byte[0..], 0) catch {};
        }

        pub fn drain(self: *const Self) void {
            var buf: [32]u8 = undefined;

            while (true) {
                _ = posix.recv(self.recv_fd, buf[0..], 0) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => return,
                };
            }
        }

        fn zeroStorage(storage: *posix.sockaddr.storage) void {
            const bytes: *[@sizeOf(posix.sockaddr.storage)]u8 = @ptrCast(storage);
            @memset(bytes, 0);
        }

        fn setNonBlocking(fd: posix.socket_t) posix.FcntlError!void {
            const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
            if ((flags & nonblock_flag) != 0) return;
            _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock_flag);
        }
    };
}
