//! Stream — internal non-blocking stream socket wrapper.
//!
//! This is the first building block for the new `net/fd` layer. It owns a
//! single socket, forces it into non-blocking mode, and implements explicit
//! poll-based connect/read/write behavior.

const context_mod = @import("context");
const AddrPort = @import("../netip/AddrPort.zig");
const sockaddr_mod = @import("SockAddr.zig");

pub fn Stream(comptime lib: type) type {
    const posix = lib.posix;
    const SockAddr = sockaddr_mod.SockAddr(lib);

    return struct {
        fd: posix.socket_t,
        closed: bool = false,
        read_deadline_ms: ?i64 = null,
        write_deadline_ms: ?i64 = null,

        const Self = @This();
        const context_poll_quantum_ms: i64 = 25;
        const nonblock_flag: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
        const max_poll_timeout_ms: i64 = 2_147_483_647;

        pub const InitError = posix.SocketError || posix.FcntlError;
        pub const AdoptError = posix.FcntlError;
        pub const ShutdownError = error{Closed} || posix.ShutdownError;
        pub const ConnectError = error{
            Closed,
            Canceled,
            DeadlineExceeded,
            ConnectFailed,
        } || SockAddr.EncodeError || posix.ConnectError || posix.PollError || posix.GetSockOptError;
        pub const ReadError = error{
            Closed,
            TimedOut,
        } || posix.RecvFromError || posix.PollError;
        pub const WriteError = error{
            Closed,
            TimedOut,
        } || posix.SendError || posix.PollError;

        const ContextStateError = error{
            Canceled,
            DeadlineExceeded,
        };

        pub fn initSocket(family: u32) InitError!Self {
            const stream_type: u32 = posix.SOCK.STREAM;
            const fd = try posix.socket(family, stream_type, 0);
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

        pub fn shutdown(self: *Self, how: posix.ShutdownHow) ShutdownError!void {
            if (self.closed) return error.Closed;
            try posix.shutdown(self.fd, how);
        }

        pub fn connect(self: *Self, addr: AddrPort) ConnectError!void {
            if (self.closed) return error.Closed;
            const encoded = try SockAddr.encode(addr);

            posix.connect(self.fd, @ptrCast(&encoded.storage), encoded.len) catch |err| switch (err) {
                error.WouldBlock, error.ConnectionPending => {},
                else => return err,
            };

            return self.waitForConnect(null);
        }

        pub fn connectContext(self: *Self, ctx: context_mod.Context, addr: AddrPort) ConnectError!void {
            if (self.closed) return error.Closed;
            try checkContext(ctx);
            const encoded = try SockAddr.encode(addr);

            posix.connect(self.fd, @ptrCast(&encoded.storage), encoded.len) catch |err| switch (err) {
                error.WouldBlock, error.ConnectionPending => {},
                else => return err,
            };

            return self.waitForConnect(ctx);
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

        fn waitForConnect(self: *Self, ctx: ?context_mod.Context) ConnectError!void {
            var poll_fds = [_]posix.pollfd{.{
                .fd = self.fd,
                .events = posix.POLL.OUT | posix.POLL.ERR | posix.POLL.HUP,
                .revents = 0,
            }};

            while (true) {
                poll_fds[0].revents = 0;
                const timeout_ms = if (ctx) |c| try contextPollTimeout(c) else -1;
                const ready = try posix.poll(poll_fds[0..], timeout_ms);
                if (ready == 0) {
                    if (ctx) |c| {
                        try checkContext(c);
                        continue;
                    }
                    continue;
                }

                var err_code: i32 = 0;
                try posix.getsockopt(self.fd, posix.SOL.SOCKET, posix.SO.ERROR, bytesOf(&err_code));
                if (err_code == 0) return;
                return connectErrorFromCode(err_code);
            }
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

        fn contextPollTimeout(ctx: context_mod.Context) ContextStateError!i32 {
            try checkContext(ctx);

            if (ctx.deadline()) |deadline_ns| {
                const remaining = @divFloor(deadline_ns - lib.time.nanoTimestamp(), lib.time.ns_per_ms);
                if (remaining <= 0) return error.DeadlineExceeded;
                return @intCast(@min(remaining, context_poll_quantum_ms));
            }

            return @intCast(context_poll_quantum_ms);
        }

        fn checkContext(ctx: context_mod.Context) ContextStateError!void {
            const cause = ctx.err() orelse return;
            if (cause == error.DeadlineExceeded) return error.DeadlineExceeded;
            return error.Canceled;
        }

        fn setNonBlocking(fd: posix.socket_t) posix.FcntlError!void {
            const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
            if ((flags & nonblock_flag) != 0) return;
            _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock_flag);
        }

        // Keep SO_ERROR-based completion aligned with the blocking connect error surface.
        fn connectErrorFromCode(code: i32) ConnectError {
            if (code == @intFromEnum(posix.E.ACCES)) return error.AccessDenied;
            if (code == @intFromEnum(posix.E.PERM)) return error.PermissionDenied;
            if (code == @intFromEnum(posix.E.ADDRINUSE)) return error.AddressInUse;
            if (code == @intFromEnum(posix.E.ADDRNOTAVAIL)) return error.AddressNotAvailable;
            if (code == @intFromEnum(posix.E.AFNOSUPPORT)) return error.AddressFamilyNotSupported;
            if (code == @intFromEnum(posix.E.CONNREFUSED)) return error.ConnectionRefused;
            // lwIP reports a refused non-blocking connect as SO_ERROR=ECONNRESET
            // on some local-loopback paths. Normalize it to ConnectionRefused.
            if (code == @intFromEnum(posix.E.CONNRESET)) return error.ConnectionRefused;
            if (code == @intFromEnum(posix.E.HOSTUNREACH)) return error.NetworkUnreachable;
            if (code == @intFromEnum(posix.E.NETUNREACH)) return error.NetworkUnreachable;
            if (code == @intFromEnum(posix.E.TIMEDOUT)) return error.ConnectionTimedOut;
            if (code == @intFromEnum(posix.E.NOENT)) return error.FileNotFound;
            return error.ConnectFailed;
        }

        fn bytesOf(ptr: anytype) []u8 {
            const Ptr = @TypeOf(ptr);
            const info = @typeInfo(Ptr);
            if (info != .pointer or info.pointer.size != .one)
                @compileError("bytesOf expects a single-item pointer");

            const T = info.pointer.child;
            const raw: [*]u8 = @ptrCast(ptr);
            return raw[0..@sizeOf(T)];
        }
    };
}
