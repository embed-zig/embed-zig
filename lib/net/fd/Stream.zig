//! Stream — internal non-blocking stream socket wrapper.
//!
//! This is the first building block for the new `net/fd` layer. It owns a
//! single socket, forces it into non-blocking mode, and implements explicit
//! poll-based connect/read/write behavior.

const context_mod = @import("context");
const AddrPort = @import("../netip/AddrPort.zig");
const sockaddr_mod = @import("SockAddr.zig");
const wake_mod = @import("Wake.zig");

const Context = context_mod.Context;

pub fn Stream(comptime lib: type) type {
    const posix = lib.posix;
    const SockAddr = sockaddr_mod.SockAddr(lib);
    const Wake = wake_mod.make(lib);

    return struct {
        fd: posix.socket_t,
        wake: Wake,
        closed: bool = false,
        read_deadline_ms: ?i64 = null,
        write_deadline_ms: ?i64 = null,

        const Self = @This();
        const ContextStateError = Context.StateError;
        const context_poll_quantum_ms: i64 = 25;
        const nonblock_flag: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
        const max_poll_timeout_ms: i64 = 2_147_483_647;

        pub const InitError = posix.SocketError || AdoptError;
        pub const AdoptError = posix.FcntlError || Wake.InitError;
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
        pub const ReadContextError = ReadError || ContextStateError;
        pub const WriteError = error{
            Closed,
            TimedOut,
        } || posix.SendError || posix.PollError;
        pub const WriteContextError = WriteError || ContextStateError;

        pub fn initSocket(family: u32) InitError!Self {
            const stream_type: u32 = posix.SOCK.STREAM;
            const fd = try posix.socket(family, stream_type, 0);
            errdefer posix.close(fd);
            return adopt(fd);
        }

        pub fn adopt(fd: posix.socket_t) AdoptError!Self {
            try setNonBlocking(fd);
            var wake = try Wake.init();
            errdefer wake.deinit();
            return .{
                .fd = fd,
                .wake = wake,
            };
        }

        pub fn deinit(self: *Self) void {
            self.close();
            self.wake.deinit();
        }

        pub fn close(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            self.wake.signal();
            posix.close(self.fd);
        }

        pub fn shutdown(self: *Self, how: posix.ShutdownHow) ShutdownError!void {
            if (self.closed) return error.Closed;
            try posix.shutdown(self.fd, how);
        }

        pub fn connect(self: *Self, addr: AddrPort) ConnectError!void {
            if (self.closed) return error.Closed;
            const encoded = try SockAddr.encode(addr);
            var pending = false;

            posix.connect(self.fd, @ptrCast(&encoded.storage), encoded.len) catch |err| switch (err) {
                error.WouldBlock, error.ConnectionPending => pending = true,
                else => return err,
            };

            if (!pending) return;
            return self.waitForConnect(null);
        }

        pub fn connectContext(self: *Self, ctx: context_mod.Context, addr: AddrPort) ConnectError!void {
            if (self.closed) return error.Closed;
            try ctx.checkState();
            const encoded = try SockAddr.encode(addr);
            var pending = false;

            posix.connect(self.fd, @ptrCast(&encoded.storage), encoded.len) catch |err| switch (err) {
                error.WouldBlock, error.ConnectionPending => pending = true,
                else => return err,
            };

            if (!pending) return;
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

        pub fn readContext(self: *Self, ctx: context_mod.Context, buf: []u8) ReadContextError!usize {
            if (self.closed) return error.Closed;
            try ctx.checkState();

            while (true) {
                const n = posix.recv(self.fd, buf, 0) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.waitForReadContext(ctx);
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

        pub fn writeContext(self: *Self, ctx: context_mod.Context, buf: []const u8) WriteContextError!usize {
            if (self.closed) return error.Closed;
            try ctx.checkState();

            while (true) {
                const n = posix.send(self.fd, buf, 0) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.waitForWriteContext(ctx);
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

        fn waitForConnect(self: *Self, ctx: ?Context) ConnectError!void {
            const events = posix.POLL.OUT | posix.POLL.ERR | posix.POLL.HUP;
            if (ctx) |c| {
                try self.waitForIoNoDeadlineContext(events, c);
            } else {
                try self.waitForIoNoDeadline(events);
            }

            var err_code: i32 = 0;
            try posix.getsockopt(self.fd, posix.SOL.SOCKET, posix.SO.ERROR, bytesOf(&err_code));
            if (err_code == 0) return;
            return connectErrorFromCode(err_code);
        }

        fn waitForRead(self: *Self) ReadError!void {
            try self.waitForIo(posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, self.read_deadline_ms);
        }

        fn waitForReadContext(self: *Self, ctx: Context) ReadContextError!void {
            try self.waitForIoContext(posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, self.read_deadline_ms, ctx);
        }

        fn waitForWrite(self: *Self) WriteError!void {
            try self.waitForIo(posix.POLL.OUT | posix.POLL.HUP | posix.POLL.ERR, self.write_deadline_ms);
        }

        fn waitForWriteContext(self: *Self, ctx: Context) WriteContextError!void {
            try self.waitForIoContext(posix.POLL.OUT | posix.POLL.HUP | posix.POLL.ERR, self.write_deadline_ms, ctx);
        }

        fn waitForIo(self: *Self, events: anytype, deadline_ms: ?i64) (error{ Closed, TimedOut } || posix.PollError)!void {
            var poll_fds = self.makePollFds(events);

            while (true) {
                poll_fds[0].revents = 0;
                poll_fds[1].revents = 0;
                const timeout_ms = timeoutFromDeadline(deadline_ms);
                const ready = posix.poll(poll_fds[0..], timeout_ms) catch |err| {
                    if (errorNameEquals(err, "Interrupted")) continue;
                    return err;
                };
                if (ready == 0) return error.TimedOut;
                if (poll_fds[0].revents != 0) {
                    if (self.closed) return error.Closed;
                    return;
                }
                if (poll_fds[1].revents != 0) {
                    self.wake.drain();
                    if (self.closed) return error.Closed;
                    continue;
                }
                return;
            }
        }

        fn waitForIoNoDeadline(self: *Self, events: anytype) (error{Closed} || posix.PollError)!void {
            var poll_fds = self.makePollFds(events);

            while (true) {
                poll_fds[0].revents = 0;
                poll_fds[1].revents = 0;
                const ready = posix.poll(poll_fds[0..], -1) catch |err| {
                    if (errorNameEquals(err, "Interrupted")) continue;
                    return err;
                };
                if (ready == 0) continue;
                if (poll_fds[0].revents != 0) {
                    if (self.closed) return error.Closed;
                    return;
                }
                if (poll_fds[1].revents != 0) {
                    self.wake.drain();
                    if (self.closed) return error.Closed;
                    continue;
                }
                return;
            }
        }

        fn waitForIoContext(
            self: *Self,
            events: anytype,
            deadline_ms: ?i64,
            ctx: Context,
        ) (error{ Closed, TimedOut } || ContextStateError || posix.PollError)!void {
            ctx.bindFd(lib, &self.wake.send_fd) catch return self.waitForIoContextFallback(events, deadline_ms, ctx);
            defer {
                ctx.bindLink(null) catch unreachable;
                if (!self.closed and ctx.err() != null) self.wake.drain();
            }

            var poll_fds = self.makePollFds(events);

            while (true) {
                poll_fds[0].revents = 0;
                poll_fds[1].revents = 0;
                const ready = posix.poll(poll_fds[0..], timeoutFromDeadline(deadline_ms)) catch |err| {
                    if (errorNameEquals(err, "Interrupted")) continue;
                    return err;
                };
                if (ready == 0) return error.TimedOut;
                if (poll_fds[0].revents != 0) {
                    if (self.closed) return error.Closed;
                    return;
                }
                if (poll_fds[1].revents != 0) {
                    self.wake.drain();
                    if (self.closed) return error.Closed;
                    try ctx.checkState();
                    continue;
                }
            }
        }

        fn waitForIoNoDeadlineContext(
            self: *Self,
            events: anytype,
            ctx: Context,
        ) (error{Closed} || ContextStateError || posix.PollError)!void {
            ctx.bindFd(lib, &self.wake.send_fd) catch return self.waitForIoNoDeadlineContextFallback(events, ctx);
            defer {
                ctx.bindLink(null) catch unreachable;
                if (!self.closed and ctx.err() != null) self.wake.drain();
            }

            var poll_fds = self.makePollFds(events);

            while (true) {
                poll_fds[0].revents = 0;
                poll_fds[1].revents = 0;
                const ready = posix.poll(poll_fds[0..], -1) catch |err| {
                    if (errorNameEquals(err, "Interrupted")) continue;
                    return err;
                };
                if (ready == 0) continue;
                if (poll_fds[0].revents != 0) {
                    if (self.closed) return error.Closed;
                    return;
                }
                if (poll_fds[1].revents != 0) {
                    self.wake.drain();
                    if (self.closed) return error.Closed;
                    try ctx.checkState();
                    continue;
                }
            }
        }

        fn waitForIoContextFallback(
            self: *Self,
            events: anytype,
            deadline_ms: ?i64,
            ctx: Context,
        ) (error{ Closed, TimedOut } || ContextStateError || posix.PollError)!void {
            var poll_fds = self.makePollFds(events);

            while (true) {
                poll_fds[0].revents = 0;
                poll_fds[1].revents = 0;
                const timeout_ms = try contextIoPollTimeout(ctx, deadline_ms);
                const ready = posix.poll(poll_fds[0..], timeout_ms) catch |err| {
                    if (errorNameEquals(err, "Interrupted")) continue;
                    return err;
                };
                if (ready == 0) {
                    ctx.checkState() catch |err| return err;
                    if (deadline_ms) |deadline| {
                        if (lib.time.milliTimestamp() >= deadline) return error.TimedOut;
                    }
                    continue;
                }
                if (poll_fds[0].revents != 0) {
                    if (self.closed) return error.Closed;
                    return;
                }
                if (poll_fds[1].revents != 0) {
                    self.wake.drain();
                    if (self.closed) return error.Closed;
                    try ctx.checkState();
                    continue;
                }
                return;
            }
        }

        fn waitForIoNoDeadlineContextFallback(
            self: *Self,
            events: anytype,
            ctx: Context,
        ) (error{Closed} || ContextStateError || posix.PollError)!void {
            var poll_fds = self.makePollFds(events);

            while (true) {
                poll_fds[0].revents = 0;
                poll_fds[1].revents = 0;
                const timeout_ms = try contextPollTimeout(ctx);
                const ready = posix.poll(poll_fds[0..], timeout_ms) catch |err| {
                    if (errorNameEquals(err, "Interrupted")) continue;
                    return err;
                };
                if (ready == 0) {
                    try ctx.checkState();
                    continue;
                }
                if (poll_fds[0].revents != 0) {
                    if (self.closed) return error.Closed;
                    return;
                }
                if (poll_fds[1].revents != 0) {
                    self.wake.drain();
                    if (self.closed) return error.Closed;
                    try ctx.checkState();
                    continue;
                }
                return;
            }
        }

        fn makePollFds(self: *Self, events: anytype) [2]posix.pollfd {
            return .{
                .{
                    .fd = self.fd,
                    .events = events,
                    .revents = 0,
                },
                .{
                    .fd = self.wake.recv_fd,
                    .events = posix.POLL.IN,
                    .revents = 0,
                },
            };
        }

        fn timeoutFromDeadline(deadline_ms: ?i64) i32 {
            const deadline = deadline_ms orelse return -1;
            const now = lib.time.milliTimestamp();
            const remaining = deadline - now;
            if (remaining <= 0) return 0;
            return @intCast(@min(remaining, max_poll_timeout_ms));
        }

        fn contextPollTimeout(ctx: Context) ContextStateError!i32 {
            try ctx.checkState();

            if (ctx.deadline()) |deadline_ns| {
                const remaining = @divFloor(deadline_ns - lib.time.nanoTimestamp(), lib.time.ns_per_ms);
                if (remaining <= 0) return error.DeadlineExceeded;
                return @intCast(@min(remaining, context_poll_quantum_ms));
            }

            return @intCast(context_poll_quantum_ms);
        }

        fn contextIoPollTimeout(ctx: Context, deadline_ms: ?i64) (error{TimedOut} || ContextStateError)!i32 {
            var timeout_ms = try contextPollTimeout(ctx);

            if (deadline_ms) |deadline| {
                const remaining = deadline - lib.time.milliTimestamp();
                if (remaining <= 0) return error.TimedOut;
                timeout_ms = @intCast(@min(@as(i64, timeout_ms), remaining));
            }

            return timeout_ms;
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
