//! Stream — internal non-blocking stream socket wrapper.
//!
//! This is the first building block for the new `net/fd` layer. It owns a
//! single socket, forces it into non-blocking mode, and implements explicit
//! poll-based connect/read/write behavior.

const context_mod = @import("context");
const AddrPort = @import("../netip/AddrPort.zig");
const netfd_mod = @import("netfd.zig");
const sockaddr_mod = @import("SockAddr.zig");

const Context = context_mod.Context;

pub fn Stream(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const posix = lib.posix;
    const NetFd = netfd_mod.make(lib);
    const SockAddr = sockaddr_mod.SockAddr(lib);

    return struct {
        fd: posix.socket_t,
        netfd: NetFd,
        closed: bool = false,

        const Self = @This();
        const nonblock_flag: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");

        pub const InitError = posix.SocketError || AdoptError;
        pub const AdoptError = posix.FcntlError || NetFd.InitError;
        pub const ShutdownError = error{Closed} || posix.ShutdownError;
        pub const ConnectError = error{
            Closed,
            Canceled,
            DeadlineExceeded,
            ConnectFailed,
        } || Allocator.Error || SockAddr.EncodeError || posix.ConnectError || posix.PollError || posix.GetSockOptError;
        pub const ReadError = error{
            Closed,
            TimedOut,
        } || Context.StateError || posix.RecvFromError || posix.PollError;
        pub const WriteError = error{
            Closed,
            TimedOut,
        } || Context.StateError || posix.SendError || posix.PollError;

        pub fn initSocket(family: u32) InitError!Self {
            const stream_type: u32 = posix.SOCK.STREAM;
            const fd = try posix.socket(family, stream_type, 0);
            errdefer posix.close(fd);
            return adopt(fd);
        }

        pub fn adopt(fd: posix.socket_t) AdoptError!Self {
            try setNonBlocking(fd);
            var netfd = try NetFd.init();
            errdefer netfd.deinit();

            return .{
                .fd = fd,
                .netfd = netfd,
            };
        }

        pub fn deinit(self: *Self) void {
            self.close();
            self.netfd.deinit();
        }

        pub fn close(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            self.clearContexts();
            self.netfd.signalAll();
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
            self.netfd.waitConnect(self.fd, &self.closed) catch |err| return switch (err) {
                error.TimedOut => error.ConnectionTimedOut,
                error.Closed => error.Closed,
                error.Canceled => error.Canceled,
                error.DeadlineExceeded => error.DeadlineExceeded,
                error.NetworkSubsystemFailed => error.NetworkSubsystemFailed,
                error.SystemResources => error.SystemResources,
                error.Unexpected => error.Unexpected,
            };
            try self.finishConnect();
        }

        pub fn connectContext(self: *Self, ctx: context_mod.Context, addr: AddrPort) ConnectError!void {
            if (self.closed) return error.Closed;
            try self.netfd.setWriteContext(ctx);
            defer self.netfd.setWriteContext(null) catch unreachable;
            try self.netfd.checkWriteContextState();
            const encoded = try SockAddr.encode(addr);
            var pending = false;

            posix.connect(self.fd, @ptrCast(&encoded.storage), encoded.len) catch |err| switch (err) {
                error.WouldBlock, error.ConnectionPending => pending = true,
                else => return err,
            };

            if (!pending) return;
            self.netfd.waitConnect(self.fd, &self.closed) catch |err| return switch (err) {
                error.TimedOut => error.ConnectionTimedOut,
                error.Closed => error.Closed,
                error.Canceled => error.Canceled,
                error.DeadlineExceeded => error.DeadlineExceeded,
                error.NetworkSubsystemFailed => error.NetworkSubsystemFailed,
                error.SystemResources => error.SystemResources,
                error.Unexpected => error.Unexpected,
            };
            try self.netfd.checkWriteContextState();
            try self.finishConnect();
        }

        pub fn read(self: *Self, buf: []u8) ReadError!usize {
            if (self.closed) return error.Closed;

            while (true) {
                try self.netfd.checkReadContextState();

                const n = posix.recv(self.fd, buf, 0) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.netfd.waitReadable(self.fd, &self.closed);
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
                try self.netfd.checkWriteContextState();

                const n = posix.send(self.fd, buf, 0) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.netfd.waitWritable(self.fd, &self.closed);
                        continue;
                    },
                    else => return err,
                };
                try self.netfd.checkWriteContextState();
                return n;
            }
        }

        pub fn setReadDeadline(self: *Self, deadline_ms: ?i64) void {
            self.netfd.setReadDeadline(deadline_ms);
        }

        pub fn setWriteDeadline(self: *Self, deadline_ms: ?i64) void {
            self.netfd.setWriteDeadline(deadline_ms);
        }

        pub fn setDeadline(self: *Self, deadline_ms: ?i64) void {
            self.netfd.setReadDeadline(deadline_ms);
            self.netfd.setWriteDeadline(deadline_ms);
        }

        pub fn setReadContext(self: *Self, ctx: ?Context) Allocator.Error!void {
            try self.netfd.setReadContext(ctx);
        }

        pub fn setWriteContext(self: *Self, ctx: ?Context) Allocator.Error!void {
            try self.netfd.setWriteContext(ctx);
        }

        pub fn clearContexts(self: *Self) void {
            self.netfd.clearContexts();
        }

        fn finishConnect(self: *Self) ConnectError!void {
            var err_code: i32 = 0;
            try posix.getsockopt(self.fd, posix.SOL.SOCKET, posix.SO.ERROR, bytesOf(&err_code));
            if (err_code == 0) return;
            return connectErrorFromCode(err_code);
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
