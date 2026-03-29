//! Packet — internal non-blocking datagram socket wrapper.
//!
//! This mirrors the `Stream` fd style for packet-oriented sockets such as UDP:
//! the socket is forced into non-blocking mode and waits are driven explicitly
//! with poll plus fd-local deadlines.

const AddrPort = @import("../netip/AddrPort.zig");
const sockaddr_mod = @import("SockAddr.zig");

pub fn Packet(comptime lib: type) type {
    const posix = lib.posix;
    const SockAddr = sockaddr_mod.SockAddr(lib);

    return struct {
        fd: posix.socket_t,
        closed: bool = false,
        read_deadline_ms: ?i64 = null,
        write_deadline_ms: ?i64 = null,

        const Self = @This();
        const nonblock_flag: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
        const max_poll_timeout_ms: i64 = 2_147_483_647;

        pub const ReadFromResult = struct {
            bytes_read: usize,
            addr: posix.sockaddr.storage,
            addr_len: posix.socklen_t,
        };

        pub const InitError = posix.SocketError || posix.FcntlError;
        pub const AdoptError = posix.FcntlError;
        pub const ConnectError = error{Closed} || SockAddr.EncodeError || posix.ConnectError;
        pub const ReadError = error{
            Closed,
            TimedOut,
        } || posix.RecvFromError || posix.PollError;
        pub const WriteError = error{
            Closed,
            TimedOut,
        } || posix.SendError || posix.PollError;
        pub const ReadFromError = error{
            Closed,
            TimedOut,
        } || posix.RecvFromError || posix.PollError;
        pub const WriteToError = error{
            Closed,
            TimedOut,
        } || SockAddr.EncodeError || posix.SendToError || posix.PollError;

        pub fn initSocket(family: u32) InitError!Self {
            const packet_type: u32 = posix.SOCK.DGRAM;
            const fd = try posix.socket(family, packet_type, 0);
            errdefer posix.close(fd);
            return adopt(fd);
        }

        pub fn adopt(fd: posix.socket_t) AdoptError!Self {
            try setNonBlocking(fd);
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

        pub fn connect(self: *Self, addr: AddrPort) ConnectError!void {
            if (self.closed) return error.Closed;
            const encoded = try SockAddr.encode(addr);
            try posix.connect(self.fd, @ptrCast(&encoded.storage), encoded.len);
        }

        pub fn read(self: *Self, buf: []u8) ReadError!usize {
            if (self.closed) return error.Closed;

            while (true) {
                const n = posix.recv(self.fd, buf, 0) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.waitForRead();
                        continue;
                    },
                    else => return err,
                };
                return n;
            }
        }

        pub fn write(self: *Self, buf: []const u8) WriteError!usize {
            if (self.closed) return error.Closed;

            while (true) {
                const n = posix.send(self.fd, buf, 0) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.waitForWrite();
                        continue;
                    },
                    else => return err,
                };
                return n;
            }
        }

        pub fn readFrom(self: *Self, buf: []u8) ReadFromError!ReadFromResult {
            if (self.closed) return error.Closed;

            while (true) {
                var result: ReadFromResult = .{
                    .bytes_read = 0,
                    .addr = undefined,
                    .addr_len = @sizeOf(posix.sockaddr.storage),
                };
                const n = posix.recvfrom(
                    self.fd,
                    buf,
                    0,
                    @ptrCast(&result.addr),
                    &result.addr_len,
                ) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.waitForRead();
                        continue;
                    },
                    else => return err,
                };
                result.bytes_read = n;
                return result;
            }
        }

        pub fn writeTo(self: *Self, buf: []const u8, addr: AddrPort) WriteToError!usize {
            if (self.closed) return error.Closed;
            const encoded = try SockAddr.encode(addr);

            while (true) {
                const n = posix.sendto(
                    self.fd,
                    buf,
                    0,
                    @ptrCast(&encoded.storage),
                    encoded.len,
                ) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.waitForWrite();
                        continue;
                    },
                    else => return err,
                };
                return n;
            }
        }

        pub fn setReadDeadline(self: *Self, deadline_ms: ?i64) void {
            self.read_deadline_ms = deadline_ms;
        }

        pub fn setWriteDeadline(self: *Self, deadline_ms: ?i64) void {
            self.write_deadline_ms = deadline_ms;
        }

        pub fn setDeadline(self: *Self, deadline_ms: ?i64) void {
            self.read_deadline_ms = deadline_ms;
            self.write_deadline_ms = deadline_ms;
        }

        fn waitForRead(self: *Self) ReadError!void {
            try waitForIo(self.fd, posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, self.read_deadline_ms);
        }

        fn waitForWrite(self: *Self) WriteError!void {
            try waitForIo(self.fd, posix.POLL.OUT | posix.POLL.HUP | posix.POLL.ERR, self.write_deadline_ms);
        }

        fn waitForIo(fd: posix.socket_t, events: anytype, deadline_ms: ?i64) (error{TimedOut} || posix.PollError)!void {
            var poll_fds = [_]posix.pollfd{.{
                .fd = fd,
                .events = events,
                .revents = 0,
            }};

            while (true) {
                poll_fds[0].revents = 0;
                const timeout_ms = timeoutFromDeadline(deadline_ms);
                const ready = try posix.poll(poll_fds[0..], timeout_ms);
                if (ready == 0) return error.TimedOut;
                return;
            }
        }

        fn timeoutFromDeadline(deadline_ms: ?i64) i32 {
            const deadline = deadline_ms orelse return -1;
            const now = lib.time.milliTimestamp();
            const remaining = deadline - now;
            if (remaining <= 0) return 0;
            return @intCast(@min(remaining, max_poll_timeout_ms));
        }

        fn setNonBlocking(fd: posix.socket_t) posix.FcntlError!void {
            const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
            if ((flags & nonblock_flag) != 0) return;
            _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock_flag);
        }
    };
}
