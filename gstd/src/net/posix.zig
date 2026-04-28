const builtin = @import("builtin");
const std = @import("std");
const glib = @import("glib");

const posix = std.posix;
const time = struct {
    const duration = glib.time.duration;
    const instant = glib.time.instant.make(@import("../time/instant.zig").impl);
};

const Wake = struct {
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

        try setWakeNonBlocking(recv_fd);

        var recv_storage: posix.sockaddr.storage = undefined;
        zeroWakeStorage(&recv_storage);
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

        try setWakeNonBlocking(send_fd);

        var send_storage: posix.sockaddr.storage = undefined;
        zeroWakeStorage(&send_storage);
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

    fn zeroWakeStorage(storage: *posix.sockaddr.storage) void {
        const bytes: *[@sizeOf(posix.sockaddr.storage)]u8 = @ptrCast(storage);
        @memset(bytes, 0);
    }

    fn setWakeNonBlocking(fd: posix.socket_t) posix.FcntlError!void {
        const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        if ((flags & nonblock_flag) != 0) return;
        _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock_flag);
    }
};

fn connectErrorFromCodeForPosix(code: i32) glib.net.runtime.SocketError {
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

pub const Tcp = struct {
    fd: posix.socket_t = -1,
    read_wake: Wake = undefined,
    write_wake: Wake = undefined,
    peer_addr: ?glib.net.netip.AddrPort = null,
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

    pub fn shutdown(self: *Self, how: glib.net.runtime.ShutdownHow) glib.net.runtime.SocketError!void {
        if (common.isClosed(self)) return error.Closed;
        const posix_how: posix.ShutdownHow = switch (how) {
            .read => .recv,
            .write => .send,
            .both => .both,
        };
        posix.shutdown(self.fd, posix_how) catch |err| return socketError(err);
    }

    pub fn signal(self: *Self, ev: glib.net.runtime.SignalEvent) void {
        common.signal(self, ev);
    }

    pub fn bind(self: *Self, addr: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (common.isClosed(self)) return error.Closed;
        const encoded = encodeSockAddr(addr) catch return error.Unexpected;
        posix.bind(self.fd, @ptrCast(&encoded.storage), encoded.len) catch |err| return socketError(err);
    }

    pub fn listen(self: *Self, backlog: u31) glib.net.runtime.SocketError!void {
        if (common.isClosed(self)) return error.Closed;
        posix.listen(self.fd, backlog) catch |err| return socketError(err);
        self.listening = true;
    }

    pub fn accept(self: *Self, remote: ?*glib.net.netip.AddrPort) glib.net.runtime.SocketError!Tcp {
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

    pub fn connect(self: *Self, addr: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (common.isClosed(self)) return error.Closed;
        self.peer_addr = addr;
        const encoded = encodeSockAddr(addr) catch return error.Unexpected;
        posix.connect(self.fd, @ptrCast(&encoded.storage), encoded.len) catch |err| return socketError(err);
    }

    pub fn finishConnect(self: *Self) glib.net.runtime.SocketError!void {
        if (common.isClosed(self)) return error.Closed;
        var err_code: i32 = 0;
        posix.getsockopt(self.fd, posix.SOL.SOCKET, posix.SO.ERROR, bytesOf(&err_code)) catch return error.Unexpected;
        if (err_code == 0) return;
        return connectErrorFromCode(err_code);
    }

    pub fn recv(self: *Self, buf: []u8) glib.net.runtime.SocketError!usize {
        if (common.isClosed(self)) return error.Closed;
        return posix.recv(self.fd, buf, 0) catch |err| return socketError(err);
    }

    pub fn send(self: *Self, buf: []const u8) glib.net.runtime.SocketError!usize {
        if (common.isClosed(self)) return error.Closed;
        return posix.send(self.fd, buf, 0) catch |err| return socketError(err);
    }

    pub fn localAddr(self: *const Self) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (common.isClosed(self)) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getsockname(self.fd, @ptrCast(&storage), &addr_len) catch |err| return socketError(err);
        return decodeSockAddr(&storage, addr_len) catch error.Unexpected;
    }

    pub fn remoteAddr(self: *const Self) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (common.isClosed(self)) return error.Closed;
        if (@hasDecl(posix, "getpeername")) {
            var storage: posix.sockaddr.storage = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            posix.getpeername(self.fd, @ptrCast(&storage), &addr_len) catch |err| return socketError(err);
            return decodeSockAddr(&storage, addr_len) catch error.Unexpected;
        }
        return self.peer_addr orelse error.NotConnected;
    }

    pub fn setOpt(self: *Self, opt: glib.net.runtime.TcpOption) glib.net.runtime.SetSockOptError!void {
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

    pub fn poll(self: *Self, want: glib.net.runtime.PollEvents, timeout: ?time.duration.Duration) glib.net.runtime.PollError!glib.net.runtime.PollEvents {
        return common.poll(self, want, timeout);
    }
};

pub const Udp = struct {
    fd: posix.socket_t = -1,
    read_wake: Wake = undefined,
    write_wake: Wake = undefined,
    peer_addr: ?glib.net.netip.AddrPort = null,
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

    pub fn signal(self: *Self, ev: glib.net.runtime.SignalEvent) void {
        common.signal(self, ev);
    }

    pub fn bind(self: *Self, addr: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (common.isClosed(self)) return error.Closed;
        const encoded = encodeSockAddr(addr) catch return error.Unexpected;
        posix.bind(self.fd, @ptrCast(&encoded.storage), encoded.len) catch |err| return socketError(err);
    }

    pub fn connect(self: *Self, addr: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (common.isClosed(self)) return error.Closed;
        self.peer_addr = addr;
        const encoded = encodeSockAddr(addr) catch return error.Unexpected;
        posix.connect(self.fd, @ptrCast(&encoded.storage), encoded.len) catch |err| return socketError(err);
    }

    pub fn finishConnect(self: *Self) glib.net.runtime.SocketError!void {
        if (common.isClosed(self)) return error.Closed;
        var err_code: i32 = 0;
        posix.getsockopt(self.fd, posix.SOL.SOCKET, posix.SO.ERROR, bytesOf(&err_code)) catch return error.Unexpected;
        if (err_code == 0) return;
        return connectErrorFromCode(err_code);
    }

    pub fn recv(self: *Self, buf: []u8) glib.net.runtime.SocketError!usize {
        if (common.isClosed(self)) return error.Closed;
        return posix.recv(self.fd, buf, 0) catch |err| return socketError(err);
    }

    pub fn recvFrom(self: *Self, buf: []u8, remote: ?*glib.net.netip.AddrPort) glib.net.runtime.SocketError!usize {
        if (common.isClosed(self)) return error.Closed;

        var remote_storage: posix.sockaddr.storage = undefined;
        var remote_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        const n = posix.recvfrom(self.fd, buf, 0, @ptrCast(&remote_storage), &remote_len) catch |err| return socketError(err);
        if (remote) |out| {
            out.* = decodeSockAddr(&remote_storage, remote_len) catch return error.Unexpected;
        }
        return n;
    }

    pub fn send(self: *Self, buf: []const u8) glib.net.runtime.SocketError!usize {
        if (common.isClosed(self)) return error.Closed;
        return posix.send(self.fd, buf, 0) catch |err| return socketError(err);
    }

    pub fn sendTo(self: *Self, buf: []const u8, addr: glib.net.netip.AddrPort) glib.net.runtime.SocketError!usize {
        if (common.isClosed(self)) return error.Closed;
        const encoded = encodeSockAddr(addr) catch return error.Unexpected;
        return posix.sendto(self.fd, buf, 0, @ptrCast(&encoded.storage), encoded.len) catch |err| return socketError(err);
    }

    pub fn localAddr(self: *const Self) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (common.isClosed(self)) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getsockname(self.fd, @ptrCast(&storage), &addr_len) catch |err| return socketError(err);
        return decodeSockAddr(&storage, addr_len) catch error.Unexpected;
    }

    pub fn remoteAddr(self: *const Self) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (common.isClosed(self)) return error.Closed;
        if (@hasDecl(posix, "getpeername")) {
            var storage: posix.sockaddr.storage = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            posix.getpeername(self.fd, @ptrCast(&storage), &addr_len) catch |err| return socketError(err);
            return decodeSockAddr(&storage, addr_len) catch error.Unexpected;
        }
        return self.peer_addr orelse error.NotConnected;
    }

    pub fn setOpt(self: *Self, opt: glib.net.runtime.UdpOption) glib.net.runtime.SetSockOptError!void {
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

    pub fn poll(self: *Self, want: glib.net.runtime.PollEvents, timeout: ?time.duration.Duration) glib.net.runtime.PollError!glib.net.runtime.PollEvents {
        return common.poll(self, want, timeout);
    }
};

pub fn tcp(domain: glib.net.runtime.Domain) glib.net.runtime.CreateError!Tcp {
    const fd = posix.socket(socketDomain(domain), posix.SOCK.STREAM, 0) catch |err| return translateCreateErr(err);
    errdefer posix.close(fd);
    return Tcp.adopt(fd) catch |err| return translateCreateErr(err);
}

pub fn udp(domain: glib.net.runtime.Domain) glib.net.runtime.CreateError!Udp {
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

        fn takeReadInterrupt(self: *Self, want: glib.net.runtime.PollEvents) bool {
            if (!want.read_interrupt) return false;
            return @atomicRmw(u8, &self.read_interrupt, .Xchg, 0, .acq_rel) != 0;
        }

        fn takeWriteInterrupt(self: *Self, want: glib.net.runtime.PollEvents) bool {
            if (!want.write_interrupt) return false;
            return @atomicRmw(u8, &self.write_interrupt, .Xchg, 0, .acq_rel) != 0;
        }

        fn adopt(fd: posix.socket_t) !Self {
            try setNonBlocking(fd);
            setNoSigPipe(fd);
            var read_wake = try Wake.init();
            errdefer read_wake.deinit();
            var write_wake = try Wake.init();
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

        fn signal(self: *Self, ev: glib.net.runtime.SignalEvent) void {
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

        fn poll(self: *Self, want: glib.net.runtime.PollEvents, timeout: ?time.duration.Duration) glib.net.runtime.PollError!glib.net.runtime.PollEvents {
            if (isClosed(self)) return error.Closed;

            const started = if (timeout != null) time.instant.now() else 0;
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

                var out = glib.net.runtime.PollEvents{
                    .read_interrupt = takeReadInterrupt(self, want),
                    .write_interrupt = takeWriteInterrupt(self, want),
                };
                if (hasAnyWantedEvent(out, want)) return out;

                poll_fds[0].revents = 0;
                if (read_wake_idx) |idx| poll_fds[idx].revents = 0;
                if (write_wake_idx) |idx| poll_fds[idx].revents = 0;

                const poll_wait_ms = if (timeout) |duration|
                    remainingTimeoutPollMs(started, duration)
                else
                    -1;

                const ready = posix.poll(poll_fds[0..poll_fd_count], poll_wait_ms) catch |err| {
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
                if (timeout) |duration| {
                    if (remainingTimeout(started, duration) == 0) return error.TimedOut;
                }
            }
        }
    };
}

const EncodedSockAddr = struct {
    storage: posix.sockaddr.storage,
    len: posix.socklen_t,
};

fn encodeSockAddr(addr_port: glib.net.netip.AddrPort) error{ InvalidAddress, InvalidScopeId }!EncodedSockAddr {
    var storage: posix.sockaddr.storage = undefined;
    zeroStorage(&storage);

    const ip = addr_port.addr();
    if (ip.is4()) {
        const sa: *posix.sockaddr.in = @ptrCast(@alignCast(&storage));
        sa.* = .{
            .port = std.mem.nativeToBig(u16, addr_port.port()),
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
            .port = std.mem.nativeToBig(u16, addr_port.port()),
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

fn decodeSockAddr(storage: *const posix.sockaddr.storage, addr_len: posix.socklen_t) error{Unexpected}!glib.net.netip.AddrPort {
    const sa_family = @as(*const posix.sockaddr, @ptrCast(storage)).family;
    return switch (sa_family) {
        posix.AF.INET => blk: {
            if (addr_len < @sizeOf(posix.sockaddr.in)) return error.Unexpected;
            const in: *const posix.sockaddr.in = @ptrCast(@alignCast(storage));
            const addr_bytes: [4]u8 = @bitCast(in.addr);
            break :blk glib.net.netip.AddrPort.from4(addr_bytes, std.mem.bigToNative(u16, in.port));
        },
        posix.AF.INET6 => blk: {
            if (addr_len < @sizeOf(posix.sockaddr.in6)) return error.Unexpected;
            const in6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(storage));
            var ip = glib.net.netip.Addr.from16(in6.addr);
            if (in6.scope_id != 0) {
                var scope_buf: [10]u8 = undefined;
                const scope = std.fmt.bufPrint(&scope_buf, "{d}", .{in6.scope_id}) catch return error.Unexpected;
                ip.zone_len = @intCast(scope.len);
                @memcpy(ip.zone[0..scope.len], scope);
            }
            break :blk glib.net.netip.AddrPort.init(ip, std.mem.bigToNative(u16, in6.port));
        },
        else => return error.Unexpected,
    };
}

fn zeroStorage(storage: *posix.sockaddr.storage) void {
    const bytes: *[@sizeOf(posix.sockaddr.storage)]u8 = @ptrCast(storage);
    @memset(bytes, 0);
}

fn parseScopeId(addr: glib.net.netip.Addr) error{InvalidScopeId}!u32 {
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

fn socketDomain(domain: glib.net.runtime.Domain) u32 {
    return switch (domain) {
        .inet => posix.AF.INET,
        .inet6 => posix.AF.INET6,
    };
}

fn socketPollMask(want: glib.net.runtime.PollEvents) i16 {
    var mask: i16 = 0;
    if (want.read) mask |= posix.POLL.IN;
    if (want.write) mask |= posix.POLL.OUT;
    if (mask == 0) mask = posix.POLL.IN | posix.POLL.OUT;
    return mask;
}

fn remainingTimeout(started: time.instant.Time, total: time.duration.Duration) time.duration.Duration {
    const elapsed = time.instant.sub(time.instant.now(), started);
    if (elapsed <= 0) return total;
    if (elapsed >= total) return 0;
    return total - elapsed;
}

fn remainingTimeoutPollMs(started: time.instant.Time, total: time.duration.Duration) i32 {
    const remaining = remainingTimeout(started, total);
    const remaining_ms = @divFloor(remaining, time.duration.MilliSecond) +
        @intFromBool(@mod(remaining, time.duration.MilliSecond) != 0);
    return @intCast(@min(remaining_ms, @as(time.duration.Duration, std.math.maxInt(i32))));
}

fn hasAnyWantedEvent(got: glib.net.runtime.PollEvents, want: glib.net.runtime.PollEvents) bool {
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

fn setSockOptBool(fd: posix.socket_t, level: anytype, opt: anytype, enable: bool) glib.net.runtime.SetSockOptError!void {
    const value: [4]u8 = @bitCast(@as(i32, if (enable) 1 else 0));
    posix.setsockopt(fd, level, opt, &value) catch |err| return setSockOptError(err);
}

fn translateCreateErr(err: anyerror) glib.net.runtime.CreateError {
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

fn setSockOptError(err: anyerror) glib.net.runtime.SetSockOptError {
    return switch (err) {
        error.NotSupported, error.ProtocolNotSupported => error.Unsupported,
        else => error.Unexpected,
    };
}

fn socketError(err: anyerror) glib.net.runtime.SocketError {
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

fn connectErrorFromCode(code: i32) glib.net.runtime.SocketError {
    return connectErrorFromCodeForPosix(code);
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
