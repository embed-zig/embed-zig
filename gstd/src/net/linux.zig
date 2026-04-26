const std = @import("std");
const glib = @import("glib");

const posix = std.posix;
const linux = std.os.linux;

const EncodeSockAddrError = error{
    InvalidAddress,
    InvalidScopeId,
};

const EncodedSockAddr = struct {
    storage: posix.sockaddr.storage,
    len: posix.socklen_t,
    family: u32,
};

fn zeroStorage(storage: *posix.sockaddr.storage) void {
    const bytes: *[@sizeOf(posix.sockaddr.storage)]u8 = @ptrCast(storage);
    @memset(bytes, 0);
}

fn mulAddU32(base: u32, factor: u32, addend: u32) error{Overflow}!u32 {
    const mul = @mulWithOverflow(base, factor);
    if (mul[1] != 0) return error.Overflow;
    const sum = @addWithOverflow(mul[0], addend);
    if (sum[1] != 0) return error.Overflow;
    return sum[0];
}

fn parseScopeId(addr: glib.net.netip.Addr) EncodeSockAddrError!u32 {
    const zone = addr.zone[0..addr.zone_len];
    if (zone.len == 0) return 0;

    var scope_id: u32 = 0;
    for (zone) |c| {
        if (c < '0' or c > '9') return error.InvalidScopeId;
        scope_id = mulAddU32(scope_id, 10, c - '0') catch return error.InvalidScopeId;
    }
    return scope_id;
}

fn encodeSockAddr(addr_port: glib.net.netip.AddrPort) EncodeSockAddrError!EncodedSockAddr {
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
            .family = posix.AF.INET,
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
            .family = posix.AF.INET6,
        };
    }

    return error.InvalidAddress;
}

fn encodeErrorToSocket(err: EncodeSockAddrError) glib.net.runtime.SocketError {
    return switch (err) {
        error.InvalidAddress => error.Unexpected,
        error.InvalidScopeId => error.Unexpected,
    };
}

fn socketDomain(domain: glib.net.runtime.Domain) u32 {
    return switch (domain) {
        .inet => posix.AF.INET,
        .inet6 => posix.AF.INET6,
    };
}

fn setNonBlocking(fd: posix.socket_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    const nonblock_flag: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
    if ((flags & nonblock_flag) != 0) return;
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock_flag);
}

fn setNoSigPipe(_: posix.socket_t) void {}

fn matchesWant(got: glib.net.runtime.PollEvents, want: glib.net.runtime.PollEvents) bool {
    return (want.read and got.read) or
        (want.write and got.write) or
        (want.failed and got.failed) or
        (want.hup and got.hup) or
        (want.read_interrupt and got.read_interrupt) or
        (want.write_interrupt and got.write_interrupt);
}

fn remainingTimeoutMs(started: std.time.Instant, total_ms: u32) glib.net.runtime.PollError!u32 {
    const now = std.time.Instant.now() catch return error.Unexpected;
    const elapsed_ms = now.since(started) / std.time.ns_per_ms;
    if (elapsed_ms >= total_ms) return 0;
    return total_ms - @as(u32, @intCast(elapsed_ms));
}

fn OpCommon(comptime Self: type) type {
    return struct {
        fn initPoll(self: *Self) !void {
            self.epfd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
            errdefer posix.close(self.epfd);

            self.wakefd = try posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            errdefer posix.close(self.wakefd);

            var sock_ev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.ERR | linux.EPOLL.HUP | linux.EPOLL.RDHUP,
                .data = .{ .fd = self.sock },
            };
            try posix.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, self.sock, &sock_ev);

            var wake_ev = linux.epoll_event{
                .events = linux.EPOLL.IN,
                .data = .{ .fd = self.wakefd },
            };
            try posix.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, self.wakefd, &wake_ev);
        }

        fn deinitPoll(self: *Self) void {
            if (self.wakefd != -1) {
                posix.close(self.wakefd);
                self.wakefd = -1;
            }
            if (self.epfd != -1) {
                posix.close(self.epfd);
                self.epfd = -1;
            }
        }

        fn triggerWake(self: *Self) void {
            if (self.wakefd == -1) return;
            var one: u64 = 1;
            _ = posix.write(self.wakefd, std.mem.asBytes(&one)) catch {};
        }

        fn drainWake(self: *Self) void {
            if (self.wakefd == -1) return;
            while (true) {
                var count: u64 = 0;
                _ = posix.read(self.wakefd, std.mem.asBytes(&count)) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => return,
                };
            }
        }

        fn signalCommon(self: *Self, ev: glib.net.runtime.SignalEvent) void {
            switch (ev) {
                .read_interrupt => @atomicStore(bool, &self.read_interrupt, true, .release),
                .write_interrupt => @atomicStore(bool, &self.write_interrupt, true, .release),
            }
            self.triggerWake();
        }

        fn takeReadInterrupt(self: *Self, want: glib.net.runtime.PollEvents) bool {
            if (!want.read_interrupt) return false;
            return @atomicRmw(bool, &self.read_interrupt, .Xchg, false, .acq_rel);
        }

        fn takeWriteInterrupt(self: *Self, want: glib.net.runtime.PollEvents) bool {
            if (!want.write_interrupt) return false;
            return @atomicRmw(bool, &self.write_interrupt, .Xchg, false, .acq_rel);
        }

        fn pollCommon(self: *Self, want: glib.net.runtime.PollEvents, timeout_ms: ?u32) glib.net.runtime.PollError!glib.net.runtime.PollEvents {
            if (self.closed) return error.Closed;

            const started: ?std.time.Instant = if (timeout_ms != null)
                (std.time.Instant.now() catch return error.Unexpected)
            else
                null;

            poll_loop: while (true) {
                var out = glib.net.runtime.PollEvents{
                    .read_interrupt = takeReadInterrupt(self, want),
                    .write_interrupt = takeWriteInterrupt(self, want),
                };
                if (matchesWant(out, want)) return out;

                const timeout: i32 = if (timeout_ms) |ms|
                    @intCast(try remainingTimeoutMs(started.?, ms))
                else
                    -1;

                var evs: [8]linux.epoll_event = undefined;
                const n = posix.epoll_wait(self.epfd, &evs, timeout);
                if (n == 0) return error.TimedOut;

                for (evs[0..n]) |ev| {
                    const revents = ev.events;
                    if (ev.data.fd == self.wakefd) {
                        drainWake(self);
                        if (takeReadInterrupt(self, want)) out.read_interrupt = true;
                        if (takeWriteInterrupt(self, want)) out.write_interrupt = true;
                        continue;
                    }

                    if (ev.data.fd == self.sock) {
                        if ((revents & linux.EPOLL.IN) != 0) out.read = true;
                        if ((revents & linux.EPOLL.OUT) != 0) out.write = true;
                        if ((revents & linux.EPOLL.ERR) != 0) out.failed = true;
                        if ((revents & (linux.EPOLL.HUP | linux.EPOLL.RDHUP)) != 0) out.hup = true;
                    }
                }

                if (matchesWant(out, want)) return out;
                if (timeout_ms) |ms| {
                    if (try remainingTimeoutMs(started.?, ms) == 0) return error.TimedOut;
                }
                continue :poll_loop;
            }
        }
    };
}

pub const Tcp = struct {
    sock: posix.socket_t = -1,
    epfd: posix.fd_t = -1,
    wakefd: posix.fd_t = -1,
    closed: bool = false,

    read_interrupt: bool = false,
    write_interrupt: bool = false,

    const tcp_ops = OpCommon(Tcp);

    pub fn close(self: *Tcp) void {
        if (self.closed) return;
        self.closed = true;
        @atomicStore(bool, &self.read_interrupt, true, .release);
        @atomicStore(bool, &self.write_interrupt, true, .release);
        self.triggerWake();

        if (self.sock != -1) {
            posix.close(self.sock);
            self.sock = -1;
        }
        self.deinitPoll();
    }

    pub fn shutdown(self: *Tcp, how: glib.net.runtime.ShutdownHow) glib.net.runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const posix_how: posix.ShutdownHow = switch (how) {
            .read => .recv,
            .write => .send,
            .both => .both,
        };
        posix.shutdown(self.sock, posix_how) catch |err| return switch (err) {
            error.SocketNotConnected => error.NotConnected,
            else => error.Unexpected,
        };
    }

    pub fn signal(self: *Tcp, ev: glib.net.runtime.SignalEvent) void {
        if (self.closed) return;
        tcp_ops.signalCommon(self, ev);
    }

    pub fn bind(self: *Tcp, ap: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        posix.bind(self.sock, @ptrCast(&enc.storage), enc.len) catch |err| return socketErr(err);
    }

    pub fn listen(self: *Tcp, backlog: u31) glib.net.runtime.SocketError!void {
        if (self.closed) return error.Closed;
        posix.listen(self.sock, backlog) catch |err| return socketErr(err);
    }

    pub fn accept(self: *Tcp, remote: ?*glib.net.netip.AddrPort) glib.net.runtime.SocketError!Tcp {
        if (self.closed) return error.Closed;

        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

        const new_fd = posix.accept(self.sock, @ptrCast(&storage), &len, 0) catch |err| return socketErr(err);
        errdefer posix.close(new_fd);

        setNonBlocking(new_fd) catch return error.Unexpected;
        setNoSigPipe(new_fd);

        var child: Tcp = .{ .sock = new_fd };
        child.initPoll() catch |err| return switch (err) {
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SystemResources,
            error.UserResourceLimitReached,
            => error.Unexpected,
            else => error.Unexpected,
        };

        if (remote) |out| {
            out.* = try sockaddrToAddrPort(&storage, len);
        }

        return child;
    }

    pub fn connect(self: *Tcp, ap: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        posix.connect(self.sock, @ptrCast(&enc.storage), enc.len) catch |err| return switch (socketErr(err)) {
            error.WouldBlock, error.ConnectionPending => {},
            else => |e| return e,
        };
    }

    pub fn finishConnect(self: *Tcp) glib.net.runtime.SocketError!void {
        if (self.closed) return error.Closed;

        var err_code: i32 = 0;
        posix.getsockopt(self.sock, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&err_code)) catch return error.Unexpected;
        if (err_code == 0) return;
        return soErrorToSocket(err_code);
    }

    pub fn recv(self: *Tcp, buf: []u8) glib.net.runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        return posix.recv(self.sock, buf, 0) catch |err| return socketErr(err);
    }

    pub fn send(self: *Tcp, buf: []const u8) glib.net.runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        return posix.send(self.sock, buf, 0) catch |err| return socketErr(err);
    }

    pub fn localAddr(self: *Tcp) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (self.closed) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getsockname(self.sock, @ptrCast(&storage), &len) catch return error.Unexpected;
        return sockaddrToAddrPort(&storage, len);
    }

    pub fn remoteAddr(self: *Tcp) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (self.closed) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getpeername(self.sock, @ptrCast(&storage), &len) catch |err| return addrQueryErr(err);
        return sockaddrToAddrPort(&storage, len);
    }

    pub fn setOpt(self: *Tcp, opt: glib.net.runtime.TcpOption) glib.net.runtime.SetSockOptError!void {
        if (self.closed) return error.Closed;
        switch (opt) {
            .socket => |s| try applySocketLevelOpt(self.sock, s),
            .tcp => |t| switch (t) {
                .no_delay => |enabled| {
                    const v: i32 = if (enabled) 1 else 0;
                    posix.setsockopt(self.sock, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&v)) catch |err| return translateSetSockOptErr(err);
                },
            },
        }
    }

    pub fn poll(self: *Tcp, want: glib.net.runtime.PollEvents, timeout_ms: ?u32) glib.net.runtime.PollError!glib.net.runtime.PollEvents {
        return tcp_ops.pollCommon(self, want, timeout_ms);
    }

    fn triggerWake(self: *Tcp) void {
        tcp_ops.triggerWake(self);
    }

    fn deinitPoll(self: *Tcp) void {
        tcp_ops.deinitPoll(self);
    }

    fn initPoll(self: *Tcp) !void {
        try tcp_ops.initPoll(self);
    }
};

pub const Udp = struct {
    sock: posix.socket_t = -1,
    epfd: posix.fd_t = -1,
    wakefd: posix.fd_t = -1,
    closed: bool = false,

    read_interrupt: bool = false,
    write_interrupt: bool = false,

    const udp_ops = OpCommon(Udp);

    pub fn close(self: *Udp) void {
        if (self.closed) return;
        self.closed = true;
        @atomicStore(bool, &self.read_interrupt, true, .release);
        @atomicStore(bool, &self.write_interrupt, true, .release);
        self.triggerWake();

        if (self.sock != -1) {
            posix.close(self.sock);
            self.sock = -1;
        }
        self.deinitPoll();
    }

    pub fn signal(self: *Udp, ev: glib.net.runtime.SignalEvent) void {
        if (self.closed) return;
        udp_ops.signalCommon(self, ev);
    }

    pub fn bind(self: *Udp, ap: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        posix.bind(self.sock, @ptrCast(&enc.storage), enc.len) catch |err| return socketErr(err);
    }

    pub fn connect(self: *Udp, ap: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        posix.connect(self.sock, @ptrCast(&enc.storage), enc.len) catch |err| return switch (socketErr(err)) {
            error.WouldBlock, error.ConnectionPending => {},
            else => |e| return e,
        };
    }

    pub fn finishConnect(self: *Udp) glib.net.runtime.SocketError!void {
        _ = self;
    }

    pub fn recv(self: *Udp, buf: []u8) glib.net.runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        return posix.recv(self.sock, buf, 0) catch |err| return socketErr(err);
    }

    pub fn recvFrom(self: *Udp, buf: []u8, src: ?*glib.net.netip.AddrPort) glib.net.runtime.SocketError!usize {
        if (self.closed) return error.Closed;

        if (src) |out| {
            var storage: posix.sockaddr.storage = undefined;
            var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            const n = posix.recvfrom(self.sock, buf, 0, @ptrCast(&storage), &len) catch |err| return socketErr(err);
            out.* = try sockaddrToAddrPort(&storage, len);
            return n;
        }

        return posix.recv(self.sock, buf, 0) catch |err| return socketErr(err);
    }

    pub fn send(self: *Udp, buf: []const u8) glib.net.runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        return posix.send(self.sock, buf, 0) catch |err| return socketErr(err);
    }

    pub fn sendTo(self: *Udp, buf: []const u8, dst: glib.net.netip.AddrPort) glib.net.runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(dst) catch |err| return encodeErrorToSocket(err);
        return posix.sendto(self.sock, buf, 0, @ptrCast(&enc.storage), enc.len) catch |err| return socketErr(err);
    }

    pub fn localAddr(self: *Udp) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (self.closed) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getsockname(self.sock, @ptrCast(&storage), &len) catch return error.Unexpected;
        return sockaddrToAddrPort(&storage, len);
    }

    pub fn remoteAddr(self: *Udp) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (self.closed) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getpeername(self.sock, @ptrCast(&storage), &len) catch |err| return addrQueryErr(err);
        return sockaddrToAddrPort(&storage, len);
    }

    pub fn setOpt(self: *Udp, opt: glib.net.runtime.UdpOption) glib.net.runtime.SetSockOptError!void {
        if (self.closed) return error.Closed;
        switch (opt) {
            .socket => |s| try applySocketLevelOpt(self.sock, s),
        }
    }

    pub fn poll(self: *Udp, want: glib.net.runtime.PollEvents, timeout_ms: ?u32) glib.net.runtime.PollError!glib.net.runtime.PollEvents {
        return udp_ops.pollCommon(self, want, timeout_ms);
    }

    fn triggerWake(self: *Udp) void {
        udp_ops.triggerWake(self);
    }

    fn deinitPoll(self: *Udp) void {
        udp_ops.deinitPoll(self);
    }

    fn initPoll(self: *Udp) !void {
        try udp_ops.initPoll(self);
    }
};

fn applySocketLevelOpt(sock: posix.socket_t, opt: glib.net.runtime.SocketLevelOption) glib.net.runtime.SetSockOptError!void {
    switch (opt) {
        .reuse_addr => |enabled| {
            const v: i32 = if (enabled) 1 else 0;
            posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&v)) catch |err| return translateSetSockOptErr(err);
        },
        .reuse_port => |enabled| {
            const v: i32 = if (enabled) 1 else 0;
            posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEPORT, std.mem.asBytes(&v)) catch |err| return translateSetSockOptErr(err);
        },
        .broadcast => |enabled| {
            const v: i32 = if (enabled) 1 else 0;
            posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&v)) catch |err| return translateSetSockOptErr(err);
        },
    }
}

fn sockaddrToAddrPort(storage: *const posix.sockaddr.storage, len: posix.socklen_t) !glib.net.netip.AddrPort {
    if (len < @sizeOf(posix.sockaddr)) return error.Unexpected;
    const family = @as(u32, @intCast(@as(*const posix.sockaddr, @ptrCast(storage)).family));

    if (family == posix.AF.INET) {
        if (len < @sizeOf(posix.sockaddr.in)) return error.Unexpected;
        const sa: *const posix.sockaddr.in = @ptrCast(@alignCast(storage));
        const port = std.mem.bigToNative(u16, sa.port);
        const addr_bytes: *align(1) const [4]u8 = @ptrCast(&sa.addr);
        return glib.net.netip.AddrPort.from4(addr_bytes.*, port);
    }

    if (family == posix.AF.INET6) {
        if (len < @sizeOf(posix.sockaddr.in6)) return error.Unexpected;
        const sa: *const posix.sockaddr.in6 = @ptrCast(@alignCast(storage));
        const port = std.mem.bigToNative(u16, sa.port);
        return glib.net.netip.AddrPort.from16(sa.addr, port);
    }

    return error.Unexpected;
}

fn translateSetSockOptErr(err: anyerror) glib.net.runtime.SetSockOptError {
    return switch (err) {
        error.NotSupported,
        error.ProtocolNotSupported,
        error.InvalidProtocolOption,
        error.OperationNotSupported,
        => error.Unsupported,
        else => error.Unexpected,
    };
}

fn socketErr(err: anyerror) glib.net.runtime.SocketError {
    return switch (err) {
        error.WouldBlock => error.WouldBlock,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.AddressInUse => error.AddressInUse,
        error.AddressNotAvailable => error.AddressNotAvailable,
        error.AlreadyConnected => error.AlreadyConnected,
        error.ConnectionAborted => error.ConnectionAborted,
        error.ConnectionPending => error.ConnectionPending,
        error.ConnectionRefused => error.ConnectionRefused,
        error.ConnectionReset, error.ConnectionResetByPeer => error.ConnectionReset,
        error.ConnectionTimedOut, error.TimedOut => error.TimedOut,
        error.MessageTooLong, error.MessageTooBig => error.MessageTooLong,
        error.NetworkUnreachable, error.HostUnreachable, error.NetUnreachable => error.NetworkUnreachable,
        error.NotConnected, error.SocketNotConnected => error.NotConnected,
        error.BrokenPipe => error.BrokenPipe,
        else => error.Unexpected,
    };
}

fn addrQueryErr(err: anyerror) glib.net.runtime.SocketError {
    return switch (err) {
        error.NotConnected, error.SocketNotConnected => error.NotConnected,
        else => error.Unexpected,
    };
}

fn soErrorToSocket(code: i32) glib.net.runtime.SocketError {
    const e = @as(posix.E, @enumFromInt(code));
    return switch (e) {
        .ACCES, .PERM => error.AccessDenied,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionReset,
        .HOSTUNREACH, .NETUNREACH => error.NetworkUnreachable,
        .TIMEDOUT => error.TimedOut,
        .ISCONN => error.AlreadyConnected,
        .NOTCONN => error.NotConnected,
        .PIPE => error.BrokenPipe,
        .MSGSIZE => error.MessageTooLong,
        else => error.Unexpected,
    };
}

pub fn tcp(domain: glib.net.runtime.Domain) glib.net.runtime.CreateError!Tcp {
    const family = socketDomain(domain);
    const sock = posix.socket(family, posix.SOCK.STREAM, 0) catch |err| return translateCreateErr(err);
    errdefer posix.close(sock);

    setNonBlocking(sock) catch return error.Unexpected;
    setNoSigPipe(sock);

    var s: Tcp = .{ .sock = sock };
    s.initPoll() catch |err| {
        s.deinitPoll();
        return switch (err) {
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SystemResources,
            error.UserResourceLimitReached,
            => error.SystemResources,
            else => error.Unexpected,
        };
    };

    return s;
}

pub fn udp(domain: glib.net.runtime.Domain) glib.net.runtime.CreateError!Udp {
    const family = socketDomain(domain);
    const sock = posix.socket(family, posix.SOCK.DGRAM, 0) catch |err| return translateCreateErr(err);
    errdefer posix.close(sock);

    setNonBlocking(sock) catch return error.Unexpected;
    setNoSigPipe(sock);

    var s: Udp = .{ .sock = sock };
    s.initPoll() catch |err| {
        s.deinitPoll();
        return switch (err) {
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SystemResources,
            error.UserResourceLimitReached,
            => error.SystemResources,
            else => error.Unexpected,
        };
    };

    return s;
}

fn translateCreateErr(err: posix.SocketError) glib.net.runtime.CreateError {
    return switch (err) {
        error.AddressFamilyNotSupported,
        error.ProtocolFamilyNotAvailable,
        error.SocketTypeNotSupported,
        error.ProtocolNotSupported,
        => error.Unsupported,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => error.SystemResources,
        else => error.Unexpected,
    };
}
