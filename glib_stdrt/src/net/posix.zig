const builtin = @import("builtin");
const net_mod = @import("glib").net;
const runtime = net_mod.runtime;
const Addr = net_mod.netip.Addr;
const AddrPort = net_mod.netip.AddrPort;

fn Wake(comptime lib: type) type {
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

fn connectErrorFromCodeForPosix(comptime posix: type, code: i32) runtime.SocketError {
    if (code == @intFromEnum(posix.E.ACCES)) return error.AccessDenied;
    if (code == @intFromEnum(posix.E.PERM)) return error.AccessDenied;
    if (code == @intFromEnum(posix.E.ADDRINUSE)) return error.AddressInUse;
    if (code == @intFromEnum(posix.E.ADDRNOTAVAIL)) return error.AddressNotAvailable;
    if (code == @intFromEnum(posix.E.ISCONN)) return error.AlreadyConnected;
    if (code == @intFromEnum(posix.E.ALREADY)) return error.ConnectionPending;
    if (code == @intFromEnum(posix.E.INPROGRESS)) return error.ConnectionPending;
    if (code == @intFromEnum(posix.E.CONNREFUSED)) return error.ConnectionRefused;
    // Darwin can surface `ECONNRESET` via `SO_ERROR` for a refused nonblocking
    // loopback connect even though the public dial contract is still refusal.
    if (code == @intFromEnum(posix.E.CONNRESET)) {
        if (builtin.os.tag == .macos) return error.ConnectionRefused;
        return error.ConnectionReset;
    }
    if (code == @intFromEnum(posix.E.HOSTUNREACH)) return error.NetworkUnreachable;
    if (code == @intFromEnum(posix.E.NETUNREACH)) return error.NetworkUnreachable;
    if (code == @intFromEnum(posix.E.NOTCONN)) return error.NotConnected;
    if (code == @intFromEnum(posix.E.TIMEDOUT)) return error.TimedOut;
    if (code == @intFromEnum(posix.E.PIPE)) return error.BrokenPipe;
    return error.Unexpected;
}

pub fn make(comptime lib: type) type {
    const posix = lib.posix;
    const WakeFd = Wake(lib);

    return struct {
        const Impl = @This();

        pub const Tcp = struct {
            fd: posix.socket_t = -1,
            read_wake: WakeFd = undefined,
            write_wake: WakeFd = undefined,
            peer_addr: ?AddrPort = null,
            closed: u8 = 0,
            listening: bool = false,
            read_interrupt: u8 = 0,
            write_interrupt: u8 = 0,

            const Self = @This();
            const common = OpCommon(Self);

            pub fn adopt(fd: posix.socket_t) !Self {
                return common.adopt(fd);
            }

            pub fn deinit(self: *Self) void {
                common.deinit(self);
            }

            pub fn close(self: *Self) void {
                common.close(self);
            }

            pub fn shutdown(self: *Self, how: runtime.ShutdownHow) runtime.SocketError!void {
                if (common.isClosed(self)) return error.Closed;
                const posix_how: posix.ShutdownHow = switch (how) {
                    .read => .recv,
                    .write => .send,
                    .both => .both,
                };
                posix.shutdown(self.fd, posix_how) catch |err| return socketError(err);
            }

            pub fn signal(self: *Self, ev: runtime.SignalEvent) void {
                common.signal(self, ev);
            }

            pub fn bind(self: *Self, addr: AddrPort) runtime.SocketError!void {
                if (common.isClosed(self)) return error.Closed;
                const encoded = encodeSockAddr(addr) catch return error.Unexpected;
                posix.bind(self.fd, @ptrCast(&encoded.storage), encoded.len) catch |err| return socketError(err);
            }

            pub fn listen(self: *Self, backlog: u31) runtime.SocketError!void {
                if (common.isClosed(self)) return error.Closed;
                posix.listen(self.fd, backlog) catch |err| return socketError(err);
                self.listening = true;
            }

            pub fn accept(self: *Self, remote: ?*AddrPort) runtime.SocketError!Tcp {
                if (common.isClosed(self)) return error.Closed;
                if (!self.listening) return error.NotConnected;

                var remote_storage: posix.sockaddr.storage = undefined;
                var remote_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
                const client_fd = posix.accept(self.fd, @ptrCast(&remote_storage), &remote_len, 0) catch |err| return socketError(err);
                errdefer posix.close(client_fd);

                var client = adopt(client_fd) catch return error.Unexpected;
                const decoded_remote = decodeSockAddr(&remote_storage, remote_len) catch return error.Unexpected;
                client.peer_addr = decoded_remote;
                if (remote) |out| out.* = decoded_remote;
                return client;
            }

            pub fn connect(self: *Self, addr: AddrPort) runtime.SocketError!void {
                if (common.isClosed(self)) return error.Closed;
                self.peer_addr = addr;
                const encoded = encodeSockAddr(addr) catch return error.Unexpected;
                posix.connect(self.fd, @ptrCast(&encoded.storage), encoded.len) catch |err| return socketError(err);
            }

            pub fn finishConnect(self: *Self) runtime.SocketError!void {
                if (common.isClosed(self)) return error.Closed;
                var err_code: i32 = 0;
                posix.getsockopt(self.fd, posix.SOL.SOCKET, posix.SO.ERROR, bytesOf(&err_code)) catch return error.Unexpected;
                if (err_code == 0) return;
                return connectErrorFromCode(err_code);
            }

            pub fn recv(self: *Self, buf: []u8) runtime.SocketError!usize {
                if (common.isClosed(self)) return error.Closed;
                return posix.recv(self.fd, buf, 0) catch |err| return socketError(err);
            }

            pub fn send(self: *Self, buf: []const u8) runtime.SocketError!usize {
                if (common.isClosed(self)) return error.Closed;
                return posix.send(self.fd, buf, 0) catch |err| return socketError(err);
            }

            pub fn localAddr(self: *const Self) runtime.SocketError!AddrPort {
                if (common.isClosed(self)) return error.Closed;
                var storage: posix.sockaddr.storage = undefined;
                var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
                posix.getsockname(self.fd, @ptrCast(&storage), &addr_len) catch |err| return socketError(err);
                return decodeSockAddr(&storage, addr_len) catch error.Unexpected;
            }

            pub fn remoteAddr(self: *const Self) runtime.SocketError!AddrPort {
                if (common.isClosed(self)) return error.Closed;
                if (@hasDecl(posix, "getpeername")) {
                    var storage: posix.sockaddr.storage = undefined;
                    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
                    posix.getpeername(self.fd, @ptrCast(&storage), &addr_len) catch |err| return socketError(err);
                    return decodeSockAddr(&storage, addr_len) catch error.Unexpected;
                }
                return self.peer_addr orelse error.NotConnected;
            }

            pub fn setOpt(self: *Self, opt: runtime.TcpOption) runtime.SetSockOptError!void {
                if (common.isClosed(self)) return error.Closed;
                switch (opt) {
                    .socket => |socket_opt| switch (socket_opt) {
                        .reuse_addr => |enable| try setSockOptBool(self.fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, enable),
                        .reuse_port => |enable| {
                            if (!@hasDecl(posix.SO, "REUSEPORT")) return error.Unsupported;
                            try setSockOptBool(self.fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, enable);
                        },
                        .broadcast => |enable| try setSockOptBool(self.fd, posix.SOL.SOCKET, posix.SO.BROADCAST, enable),
                    },
                    .tcp => |tcp_opt| switch (tcp_opt) {
                        .no_delay => |enable| {
                            if (!@hasDecl(posix, "TCP") or !@hasDecl(posix.TCP, "NODELAY")) return error.Unsupported;
                            try setSockOptBool(self.fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, enable);
                        },
                    },
                }
            }

            pub fn poll(self: *Self, want: runtime.PollEvents, timeout_ms: ?u32) runtime.PollError!runtime.PollEvents {
                return common.poll(self, want, timeout_ms);
            }
        };

        pub const Udp = struct {
            fd: posix.socket_t = -1,
            read_wake: WakeFd = undefined,
            write_wake: WakeFd = undefined,
            peer_addr: ?AddrPort = null,
            closed: u8 = 0,
            read_interrupt: u8 = 0,
            write_interrupt: u8 = 0,

            const Self = @This();
            const common = OpCommon(Self);

            pub fn adopt(fd: posix.socket_t) !Self {
                return common.adopt(fd);
            }

            pub fn deinit(self: *Self) void {
                common.deinit(self);
            }

            pub fn close(self: *Self) void {
                common.close(self);
            }

            pub fn signal(self: *Self, ev: runtime.SignalEvent) void {
                common.signal(self, ev);
            }

            pub fn bind(self: *Self, addr: AddrPort) runtime.SocketError!void {
                if (common.isClosed(self)) return error.Closed;
                const encoded = encodeSockAddr(addr) catch return error.Unexpected;
                posix.bind(self.fd, @ptrCast(&encoded.storage), encoded.len) catch |err| return socketError(err);
            }

            pub fn connect(self: *Self, addr: AddrPort) runtime.SocketError!void {
                if (common.isClosed(self)) return error.Closed;
                self.peer_addr = addr;
                const encoded = encodeSockAddr(addr) catch return error.Unexpected;
                posix.connect(self.fd, @ptrCast(&encoded.storage), encoded.len) catch |err| return socketError(err);
            }

            pub fn finishConnect(self: *Self) runtime.SocketError!void {
                if (common.isClosed(self)) return error.Closed;
                var err_code: i32 = 0;
                posix.getsockopt(self.fd, posix.SOL.SOCKET, posix.SO.ERROR, bytesOf(&err_code)) catch return error.Unexpected;
                if (err_code == 0) return;
                return connectErrorFromCode(err_code);
            }

            pub fn recv(self: *Self, buf: []u8) runtime.SocketError!usize {
                if (common.isClosed(self)) return error.Closed;
                return posix.recv(self.fd, buf, 0) catch |err| return socketError(err);
            }

            pub fn recvFrom(self: *Self, buf: []u8, remote: ?*AddrPort) runtime.SocketError!usize {
                if (common.isClosed(self)) return error.Closed;

                var remote_storage: posix.sockaddr.storage = undefined;
                var remote_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
                const n = posix.recvfrom(self.fd, buf, 0, @ptrCast(&remote_storage), &remote_len) catch |err| return socketError(err);
                if (remote) |out| {
                    out.* = decodeSockAddr(&remote_storage, remote_len) catch return error.Unexpected;
                }
                return n;
            }

            pub fn send(self: *Self, buf: []const u8) runtime.SocketError!usize {
                if (common.isClosed(self)) return error.Closed;
                return posix.send(self.fd, buf, 0) catch |err| return socketError(err);
            }

            pub fn sendTo(self: *Self, buf: []const u8, addr: AddrPort) runtime.SocketError!usize {
                if (common.isClosed(self)) return error.Closed;
                const encoded = encodeSockAddr(addr) catch return error.Unexpected;
                return posix.sendto(self.fd, buf, 0, @ptrCast(&encoded.storage), encoded.len) catch |err| return socketError(err);
            }

            pub fn localAddr(self: *const Self) runtime.SocketError!AddrPort {
                if (common.isClosed(self)) return error.Closed;
                var storage: posix.sockaddr.storage = undefined;
                var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
                posix.getsockname(self.fd, @ptrCast(&storage), &addr_len) catch |err| return socketError(err);
                return decodeSockAddr(&storage, addr_len) catch error.Unexpected;
            }

            pub fn remoteAddr(self: *const Self) runtime.SocketError!AddrPort {
                if (common.isClosed(self)) return error.Closed;
                if (@hasDecl(posix, "getpeername")) {
                    var storage: posix.sockaddr.storage = undefined;
                    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
                    posix.getpeername(self.fd, @ptrCast(&storage), &addr_len) catch |err| return socketError(err);
                    return decodeSockAddr(&storage, addr_len) catch error.Unexpected;
                }
                return self.peer_addr orelse error.NotConnected;
            }

            pub fn setOpt(self: *Self, opt: runtime.UdpOption) runtime.SetSockOptError!void {
                if (common.isClosed(self)) return error.Closed;
                switch (opt) {
                    .socket => |socket_opt| switch (socket_opt) {
                        .reuse_addr => |enable| try setSockOptBool(self.fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, enable),
                        .reuse_port => |enable| {
                            if (!@hasDecl(posix.SO, "REUSEPORT")) return error.Unsupported;
                            try setSockOptBool(self.fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, enable);
                        },
                        .broadcast => |enable| try setSockOptBool(self.fd, posix.SOL.SOCKET, posix.SO.BROADCAST, enable),
                    },
                }
            }

            pub fn poll(self: *Self, want: runtime.PollEvents, timeout_ms: ?u32) runtime.PollError!runtime.PollEvents {
                return common.poll(self, want, timeout_ms);
            }
        };

        pub fn tcp(domain: runtime.Domain) runtime.CreateError!Tcp {
            const fd = posix.socket(socketDomain(domain), posix.SOCK.STREAM, 0) catch |err| return translateCreateErr(err);
            errdefer posix.close(fd);
            return Tcp.adopt(fd) catch |err| return translateCreateErr(err);
        }

        pub fn udp(domain: runtime.Domain) runtime.CreateError!Udp {
            const fd = posix.socket(socketDomain(domain), posix.SOCK.DGRAM, 0) catch |err| return translateCreateErr(err);
            errdefer posix.close(fd);
            return Udp.adopt(fd) catch |err| return translateCreateErr(err);
        }

        fn OpCommon(comptime Self: type) type {
            return struct {
                fn isClosed(self: *const Self) bool {
                    return @atomicLoad(u8, &self.closed, .acquire) != 0;
                }

                fn hasReadInterrupt(self: *const Self) bool {
                    return @atomicLoad(u8, &self.read_interrupt, .acquire) != 0;
                }

                fn hasWriteInterrupt(self: *const Self) bool {
                    return @atomicLoad(u8, &self.write_interrupt, .acquire) != 0;
                }

                fn takeReadInterrupt(self: *Self, want: runtime.PollEvents) bool {
                    if (!want.read_interrupt) return false;
                    return @atomicRmw(u8, &self.read_interrupt, .Xchg, 0, .acq_rel) != 0;
                }

                fn takeWriteInterrupt(self: *Self, want: runtime.PollEvents) bool {
                    if (!want.write_interrupt) return false;
                    return @atomicRmw(u8, &self.write_interrupt, .Xchg, 0, .acq_rel) != 0;
                }

                fn adopt(fd: posix.socket_t) !Self {
                    try setNonBlocking(fd);
                    setNoSigPipe(fd);
                    var read_wake = try WakeFd.init();
                    errdefer read_wake.deinit();
                    var write_wake = try WakeFd.init();
                    errdefer write_wake.deinit();
                    return .{
                        .fd = fd,
                        .read_wake = read_wake,
                        .write_wake = write_wake,
                    };
                }

                fn close(self: *Self) void {
                    if (@cmpxchgStrong(u8, &self.closed, 0, 1, .acq_rel, .acquire) != null) return;
                    @atomicStore(u8, &self.read_interrupt, 1, .release);
                    @atomicStore(u8, &self.write_interrupt, 1, .release);
                    self.read_wake.signal();
                    self.write_wake.signal();
                    if (self.fd != -1) {
                        posix.close(self.fd);
                        self.fd = -1;
                    }
                }

                fn deinit(self: *Self) void {
                    if (!isClosed(self)) close(self);
                    self.read_wake.deinit();
                    self.write_wake.deinit();
                }

                fn signal(self: *Self, ev: runtime.SignalEvent) void {
                    if (isClosed(self)) return;
                    switch (ev) {
                        .read_interrupt => {
                            @atomicStore(u8, &self.read_interrupt, 1, .release);
                            self.read_wake.signal();
                        },
                        .write_interrupt => {
                            @atomicStore(u8, &self.write_interrupt, 1, .release);
                            self.write_wake.signal();
                        },
                    }
                }

                fn poll(self: *Self, want: runtime.PollEvents, timeout_ms: ?u32) runtime.PollError!runtime.PollEvents {
                    if (isClosed(self)) return error.Closed;

                    const started_ms = if (timeout_ms != null) lib.time.milliTimestamp() else 0;
                    var poll_fds: [3]posix.pollfd = undefined;
                    poll_fds[0] = .{
                        .fd = self.fd,
                        .events = socketPollMask(want),
                        .revents = 0,
                    };
                    var poll_fd_count: usize = 1;
                    const read_wake_idx: ?usize = if (want.read_interrupt) blk: {
                        poll_fds[poll_fd_count] = .{
                            .fd = self.read_wake.recv_fd,
                            .events = posix.POLL.IN,
                            .revents = 0,
                        };
                        const idx = poll_fd_count;
                        poll_fd_count += 1;
                        break :blk idx;
                    } else null;
                    const write_wake_idx: ?usize = if (want.write_interrupt) blk: {
                        poll_fds[poll_fd_count] = .{
                            .fd = self.write_wake.recv_fd,
                            .events = posix.POLL.IN,
                            .revents = 0,
                        };
                        const idx = poll_fd_count;
                        poll_fd_count += 1;
                        break :blk idx;
                    } else null;

                    while (true) {
                        if (isClosed(self)) return error.Closed;

                        var out = runtime.PollEvents{
                            .read_interrupt = takeReadInterrupt(self, want),
                            .write_interrupt = takeWriteInterrupt(self, want),
                        };
                        if (hasAnyWantedEvent(out, want)) return out;

                        poll_fds[0].revents = 0;
                        if (read_wake_idx) |idx| poll_fds[idx].revents = 0;
                        if (write_wake_idx) |idx| poll_fds[idx].revents = 0;

                        const timeout = if (timeout_ms) |ms|
                            @as(i32, @intCast(remainingTimeoutMs(started_ms, ms)))
                        else
                            -1;

                        const ready = posix.poll(poll_fds[0..poll_fd_count], timeout) catch |err| {
                            if (errorNameEquals(err, "Interrupted")) continue;
                            return error.Unexpected;
                        };
                        if (ready == 0) return error.TimedOut;

                        if (read_wake_idx) |idx| {
                            if (poll_fds[idx].revents != 0) {
                                self.read_wake.drain();
                                out.read_interrupt = takeReadInterrupt(self, want);
                            }
                        }
                        if (write_wake_idx) |idx| {
                            if (poll_fds[idx].revents != 0) {
                                self.write_wake.drain();
                                out.write_interrupt = takeWriteInterrupt(self, want);
                            }
                        }

                        if (poll_fds[0].revents != 0) {
                            const revents = poll_fds[0].revents;
                            if ((revents & posix.POLL.IN) != 0) out.read = true;
                            if ((revents & posix.POLL.OUT) != 0) out.write = true;
                            if ((revents & posix.POLL.ERR) != 0) out.failed = true;
                            if ((revents & posix.POLL.HUP) != 0) out.hup = true;
                        }

                        if (hasAnyWantedEvent(out, want)) return out;
                        if (timeout_ms) |ms| {
                            if (remainingTimeoutMs(started_ms, ms) == 0) return error.TimedOut;
                        }
                    }
                }
            };
        }

        const EncodedSockAddr = struct {
            storage: posix.sockaddr.storage,
            len: posix.socklen_t,
        };

        fn encodeSockAddr(addr_port: AddrPort) error{ InvalidAddress, InvalidScopeId }!EncodedSockAddr {
            var storage: posix.sockaddr.storage = undefined;
            zeroStorage(&storage);

            const ip = addr_port.addr();
            if (ip.is4()) {
                const sa: *posix.sockaddr.in = @ptrCast(@alignCast(&storage));
                sa.* = .{
                    .port = lib.mem.nativeToBig(u16, addr_port.port()),
                    .addr = @as(*align(1) const u32, @ptrCast(&ip.as4().?)).*,
                };
                return .{
                    .storage = storage,
                    .len = @sizeOf(posix.sockaddr.in),
                };
            }

            if (ip.is6()) {
                const sa: *posix.sockaddr.in6 = @ptrCast(@alignCast(&storage));
                sa.* = .{
                    .port = lib.mem.nativeToBig(u16, addr_port.port()),
                    .flowinfo = 0,
                    .addr = ip.as16().?,
                    .scope_id = try parseScopeId(ip),
                };
                return .{
                    .storage = storage,
                    .len = @sizeOf(posix.sockaddr.in6),
                };
            }

            return error.InvalidAddress;
        }

        fn decodeSockAddr(storage: *const posix.sockaddr.storage, addr_len: posix.socklen_t) error{Unexpected}!AddrPort {
            const sa_family = @as(*const posix.sockaddr, @ptrCast(storage)).family;
            return switch (sa_family) {
                posix.AF.INET => blk: {
                    if (addr_len < @sizeOf(posix.sockaddr.in)) return error.Unexpected;
                    const in: *const posix.sockaddr.in = @ptrCast(@alignCast(storage));
                    const addr_bytes: [4]u8 = @bitCast(in.addr);
                    break :blk AddrPort.from4(addr_bytes, lib.mem.bigToNative(u16, in.port));
                },
                posix.AF.INET6 => blk: {
                    if (addr_len < @sizeOf(posix.sockaddr.in6)) return error.Unexpected;
                    const in6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(storage));
                    var ip = Addr.from16(in6.addr);
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

        fn zeroStorage(storage: *posix.sockaddr.storage) void {
            const bytes: *[@sizeOf(posix.sockaddr.storage)]u8 = @ptrCast(storage);
            @memset(bytes, 0);
        }

        fn parseScopeId(addr: Addr) error{ InvalidScopeId }!u32 {
            const zone = addr.zone[0..addr.zone_len];
            if (zone.len == 0) return 0;

            var scope_id: u32 = 0;
            for (zone) |c| {
                if (c < '0' or c > '9') return error.InvalidScopeId;
                scope_id = mulAddU32(scope_id, 10, c - '0') catch return error.InvalidScopeId;
            }
            return scope_id;
        }

        fn mulAddU32(base: u32, factor: u32, addend: u32) error{Overflow}!u32 {
            const mul = @mulWithOverflow(base, factor);
            if (mul[1] != 0) return error.Overflow;
            const sum = @addWithOverflow(mul[0], addend);
            if (sum[1] != 0) return error.Overflow;
            return sum[0];
        }

        fn socketDomain(domain: runtime.Domain) u32 {
            return switch (domain) {
                .inet => posix.AF.INET,
                .inet6 => posix.AF.INET6,
            };
        }

        fn socketPollMask(want: runtime.PollEvents) i16 {
            var mask: i16 = 0;
            if (want.read) mask |= posix.POLL.IN;
            if (want.write) mask |= posix.POLL.OUT;
            if (mask == 0) mask = posix.POLL.IN | posix.POLL.OUT;
            return mask;
        }

        fn remainingTimeoutMs(started_ms: i64, total_ms: u32) u32 {
            const elapsed = lib.time.milliTimestamp() - started_ms;
            if (elapsed <= 0) return total_ms;
            if (elapsed >= total_ms) return 0;
            return total_ms - @as(u32, @intCast(elapsed));
        }

        fn hasAnyWantedEvent(got: runtime.PollEvents, want: runtime.PollEvents) bool {
            return (want.read and got.read) or
                (want.write and got.write) or
                (want.failed and got.failed) or
                (want.hup and got.hup) or
                (want.read_interrupt and got.read_interrupt) or
                (want.write_interrupt and got.write_interrupt);
        }

        fn setNonBlocking(fd: posix.socket_t) !void {
            const nonblock_flag: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
            const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
            if ((flags & nonblock_flag) != 0) return;
            _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock_flag);
        }

        fn setNoSigPipe(fd: posix.socket_t) void {
            if (!@hasDecl(posix.SO, "NOSIGPIPE")) return;
            const value: [4]u8 = @bitCast(@as(i32, 1));
            posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, &value) catch {};
        }

        fn setSockOptBool(fd: posix.socket_t, level: anytype, opt: anytype, enable: bool) runtime.SetSockOptError!void {
            const value: [4]u8 = @bitCast(@as(i32, if (enable) 1 else 0));
            posix.setsockopt(fd, level, opt, &value) catch |err| return setSockOptError(err);
        }

        fn translateCreateErr(err: anyerror) runtime.CreateError {
            return switch (err) {
                error.AddressFamilyNotSupported,
                error.ProtocolFamilyNotAvailable,
                error.SocketTypeNotSupported,
                error.ProtocolNotSupported,
                => error.Unsupported,
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                error.SystemResources,
                => error.SystemResources,
                error.OutOfMemory => error.OutOfMemory,
                else => error.Unexpected,
            };
        }

        fn setSockOptError(err: anyerror) runtime.SetSockOptError {
            return switch (err) {
                error.NotSupported, error.ProtocolNotSupported => error.Unsupported,
                else => error.Unexpected,
            };
        }

        fn socketError(err: anyerror) runtime.SocketError {
            return switch (err) {
                error.WouldBlock => error.WouldBlock,
                error.AccessDenied, error.PermissionDenied => error.AccessDenied,
                error.AddressInUse => error.AddressInUse,
                error.AddressNotAvailable => error.AddressNotAvailable,
                error.AlreadyConnected => error.AlreadyConnected,
                error.ConnectionPending => error.ConnectionPending,
                error.ConnectionAborted => error.ConnectionAborted,
                error.ConnectionRefused => error.ConnectionRefused,
                error.ConnectionReset,
                error.ConnectionResetByPeer,
                => error.ConnectionReset,
                error.BrokenPipe => error.BrokenPipe,
                error.MessageTooLong,
                error.MessageTooBig,
                => error.MessageTooLong,
                error.NetworkUnreachable,
                error.HostUnreachable,
                error.NetUnreachable,
                => error.NetworkUnreachable,
                error.NotConnected,
                error.SocketNotConnected,
                => error.NotConnected,
                error.ConnectionTimedOut,
                error.TimedOut,
                => error.TimedOut,
                else => error.Unexpected,
            };
        }

        fn connectErrorFromCode(code: i32) runtime.SocketError {
            return connectErrorFromCodeForPosix(posix, code);
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
