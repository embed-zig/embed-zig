//! Packet — internal non-blocking datagram socket wrapper.
//!
//! This mirrors the `Stream` fd style for packet-oriented sockets such as UDP:
//! the socket is forced into non-blocking mode and waits are driven explicitly
//! with poll plus fd-local deadlines.

const context_mod = @import("context");
const AddrPort = @import("../netip/AddrPort.zig");
const netfd_mod = @import("netfd.zig");
const sockaddr_mod = @import("SockAddr.zig");

const Context = context_mod.Context;

pub fn Packet(comptime lib: type) type {
    const posix = lib.posix;
    const Allocator = lib.mem.Allocator;
    const NetFd = netfd_mod.make(lib);
    const SockAddr = sockaddr_mod.SockAddr(lib);

    return struct {
        fd: posix.socket_t,
        netfd: NetFd,
        closed: bool = false,

        const Self = @This();
        const nonblock_flag: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");

        pub const ReadFromResult = struct {
            bytes_read: usize,
            addr: posix.sockaddr.storage,
            addr_len: posix.socklen_t,
        };

        pub const InitError = posix.SocketError || AdoptError;
        pub const AdoptError = posix.FcntlError || NetFd.InitError;
        pub const ConnectError = error{
            Closed,
            Canceled,
            DeadlineExceeded,
            ConnectFailed,
        } || Allocator.Error || SockAddr.EncodeError || posix.ConnectError || posix.PollError || posix.GetSockOptError;
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
            self.netfd.clearContexts();
            self.netfd.signalAll();
            posix.close(self.fd);
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
                error.Canceled => unreachable,
                error.DeadlineExceeded => unreachable,
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
                const n = posix.recv(self.fd, buf, 0) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.netfd.waitReadable(self.fd, &self.closed) catch |wait_err| switch (wait_err) {
                            error.Closed => return error.Closed,
                            error.TimedOut => return error.TimedOut,
                            error.Canceled, error.DeadlineExceeded => unreachable,
                            error.NetworkSubsystemFailed => return error.NetworkSubsystemFailed,
                            error.SystemResources => return error.SystemResources,
                            error.Unexpected => return error.Unexpected,
                        };
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
                        self.netfd.waitWritable(self.fd, &self.closed) catch |wait_err| switch (wait_err) {
                            error.Closed => return error.Closed,
                            error.TimedOut => return error.TimedOut,
                            error.Canceled, error.DeadlineExceeded => unreachable,
                            error.NetworkSubsystemFailed => return error.NetworkSubsystemFailed,
                            error.SystemResources => return error.SystemResources,
                            error.Unexpected => return error.Unexpected,
                        };
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
                        self.netfd.waitReadable(self.fd, &self.closed) catch |wait_err| switch (wait_err) {
                            error.Closed => return error.Closed,
                            error.TimedOut => return error.TimedOut,
                            error.Canceled, error.DeadlineExceeded => unreachable,
                            error.NetworkSubsystemFailed => return error.NetworkSubsystemFailed,
                            error.SystemResources => return error.SystemResources,
                            error.Unexpected => return error.Unexpected,
                        };
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
                        self.netfd.waitWritable(self.fd, &self.closed) catch |wait_err| switch (wait_err) {
                            error.Closed => return error.Closed,
                            error.TimedOut => return error.TimedOut,
                            error.Canceled, error.DeadlineExceeded => unreachable,
                            error.NetworkSubsystemFailed => return error.NetworkSubsystemFailed,
                            error.SystemResources => return error.SystemResources,
                            error.Unexpected => return error.Unexpected,
                        };
                        continue;
                    },
                    else => return err,
                };
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
