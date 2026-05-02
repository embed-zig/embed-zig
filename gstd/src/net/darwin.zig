const std = @import("std");
const glib = @import("glib");

const posix = std.posix;
const system = posix.system;
const EV = std.c.EV;
const NOTE = std.c.NOTE;
const EVFILT = std.c.EVFILT;
const time = struct {
    const duration = glib.time.duration;
    const instant = glib.time.instant.make(@import("../time/instant.zig").impl);
};

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

fn setNoSigPipe(fd: posix.socket_t) void {
    const enable: [4]u8 = @bitCast(@as(i32, 1));
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, &enable) catch {};
}

fn wakeUserEvent(ident: usize) posix.Kevent {
    return .{
        .ident = ident,
        .filter = system.EVFILT.USER,
        .flags = 0,
        .fflags = NOTE.TRIGGER,
        .data = 0,
        .udata = 0,
    };
}

fn OpCommon(comptime Self: type) type {
    return struct {
        fn socketIdent(self: *const Self) usize {
            return self.socket_ident;
        }

        fn readWakeIdent(self: *const Self) usize {
            return self.read_wake_ident;
        }

        fn writeWakeIdent(self: *const Self) usize {
            return self.write_wake_ident;
        }

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

        fn initKq(self: *Self) !void {
            self.kq = try posix.kqueue();
            self.socket_ident = @as(usize, @intCast(self.sock));
            const wake_base = socketIdent(self) << 1;
            self.read_wake_ident = wake_base | 1;
            self.write_wake_ident = wake_base | 2;

            const adds = [4]posix.Kevent{
                .{
                    .ident = readWakeIdent(self),
                    .filter = system.EVFILT.USER,
                    .flags = EV.ADD | EV.CLEAR,
                    .fflags = NOTE.FFNOP,
                    .data = 0,
                    .udata = 0,
                },
                .{
                    .ident = writeWakeIdent(self),
                    .filter = system.EVFILT.USER,
                    .flags = EV.ADD | EV.CLEAR,
                    .fflags = NOTE.FFNOP,
                    .data = 0,
                    .udata = 0,
                },
                .{
                    .ident = socketIdent(self),
                    .filter = system.EVFILT.READ,
                    .flags = EV.ADD,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                },
                .{
                    .ident = socketIdent(self),
                    .filter = system.EVFILT.WRITE,
                    .flags = EV.ADD,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                },
            };
            _ = try posix.kevent(self.kq, &adds, &.{}, null);
        }

        fn deinitKq(self: *Self) void {
            if (self.kq != -1) {
                posix.close(self.kq);
                self.kq = -1;
            }
        }

        fn triggerWake(self: *Self, ident: usize) void {
            if (self.kq == -1) return;
            const ev = wakeUserEvent(ident);
            _ = posix.kevent(self.kq, &.{ev}, &.{}, null) catch {};
        }

        fn triggerReadWake(self: *Self) void {
            triggerWake(self, readWakeIdent(self));
        }

        fn triggerWriteWake(self: *Self) void {
            triggerWake(self, writeWakeIdent(self));
        }

        fn signalCommon(self: *Self, ev: glib.net.runtime.SignalEvent) void {
            if (isClosed(self)) return;
            switch (ev) {
                .read_interrupt => {
                    @atomicStore(u8, &self.read_interrupt, 1, .release);
                    self.triggerReadWake();
                },
                .write_interrupt => {
                    @atomicStore(u8, &self.write_interrupt, 1, .release);
                    self.triggerWriteWake();
                },
            }
        }

        fn pollCommon(self: *Self, want: glib.net.runtime.PollEvents, timeout: ?time.duration.Duration) glib.net.runtime.PollError!glib.net.runtime.PollEvents {
            if (isClosed(self)) return error.Closed;
            if (self.kq == -1) return error.Unexpected;
            const started = if (timeout != null) time.instant.now() else 0;

            while (true) {
                if (isClosed(self)) return error.Closed;

                var out = glib.net.runtime.PollEvents{
                    .read_interrupt = takeReadInterrupt(self, want),
                    .write_interrupt = takeWriteInterrupt(self, want),
                };
                if (hasAnyWantedEvent(out, want)) return out;

                var ts: posix.timespec = undefined;
                const timeout_ptr: ?*const posix.timespec = blk: {
                    const t = timeout orelse break :blk null;
                    const remaining = remainingTimeout(started, t);
                    ts = .{
                        .sec = @as(isize, @intCast(@divFloor(remaining, time.duration.Second))),
                        .nsec = @as(isize, @intCast(@mod(remaining, time.duration.Second))),
                    };
                    break :blk &ts;
                };

                var evs: [8]posix.Kevent = undefined;
                const n = posix.kevent(self.kq, &.{}, &evs, timeout_ptr) catch return error.Unexpected;

                if (n == 0) {
                    if (timeout != null) return error.TimedOut;
                    continue;
                }

                for (evs[0..n]) |kev| {
                    if (kev.filter == system.EVFILT.USER and kev.ident == readWakeIdent(self)) {
                        if (want.read_interrupt) {
                            if (takeReadInterrupt(self, want)) out.read_interrupt = true;
                        } else if (hasReadInterrupt(self)) {
                            self.triggerReadWake();
                        }
                        continue;
                    }

                    if (kev.filter == system.EVFILT.USER and kev.ident == writeWakeIdent(self)) {
                        if (want.write_interrupt) {
                            if (takeWriteInterrupt(self, want)) out.write_interrupt = true;
                        } else if (hasWriteInterrupt(self)) {
                            self.triggerWriteWake();
                        }
                        continue;
                    }

                    if (kev.ident == socketIdent(self)) {
                        if (kev.filter == system.EVFILT.READ) {
                            if ((kev.flags & EV.ERROR) != 0) {
                                out.failed = true;
                            }
                            if ((kev.flags & EV.EOF) != 0) {
                                out.hup = true;
                            }
                            out.read = true;
                        } else if (kev.filter == system.EVFILT.WRITE) {
                            if ((kev.flags & EV.ERROR) != 0) {
                                out.failed = true;
                            }
                            out.write = true;
                        }
                    }
                }

                if (hasAnyWantedEvent(out, want)) return out;

                if (timeout) |duration| {
                    if (remainingTimeout(started, duration) == 0) return error.TimedOut;
                }
            }
        }
    };
}

pub const Tcp = struct {
    sock: posix.socket_t = -1,
    kq: posix.fd_t = -1,
    socket_ident: usize = 0,
    read_wake_ident: usize = 0,
    write_wake_ident: usize = 0,
    closed: u8 = 0,

    read_interrupt: u8 = 0,
    write_interrupt: u8 = 0,

    const tcp_ops = OpCommon(Tcp);

    pub fn close(self: *Tcp) void {
        if (@cmpxchgStrong(u8, &self.closed, 0, 1, .acq_rel, .acquire) != null) return;
        @atomicStore(u8, &self.read_interrupt, 1, .release);
        @atomicStore(u8, &self.write_interrupt, 1, .release);
        self.triggerReadWake();
        self.triggerWriteWake();

        if (self.sock != -1) {
            posix.close(self.sock);
            self.sock = -1;
        }
    }

    pub fn deinit(self: *Tcp) void {
        self.close();
        self.deinitKq();
    }

    pub fn shutdown(self: *Tcp, how: glib.net.runtime.ShutdownHow) glib.net.runtime.SocketError!void {
        if (tcp_ops.isClosed(self)) return error.Closed;
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
        if (tcp_ops.isClosed(self)) return;
        tcp_ops.signalCommon(self, ev);
    }

    pub fn bind(self: *Tcp, ap: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (tcp_ops.isClosed(self)) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        posix.bind(self.sock, @ptrCast(&enc.storage), enc.len) catch |err| return socketError(err);
    }

    pub fn listen(self: *Tcp, backlog: u31) glib.net.runtime.SocketError!void {
        if (tcp_ops.isClosed(self)) return error.Closed;
        posix.listen(self.sock, backlog) catch |err| return socketError(err);
    }

    pub fn accept(self: *Tcp, remote: ?*glib.net.netip.AddrPort) glib.net.runtime.SocketError!Tcp {
        if (tcp_ops.isClosed(self)) return error.Closed;

        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

        const new_fd = posix.accept(self.sock, @ptrCast(&storage), &len, 0) catch |err| return socketError(err);
        errdefer posix.close(new_fd);

        setNonBlocking(new_fd) catch return error.Unexpected;
        setNoSigPipe(new_fd);

        var child: Tcp = .{ .sock = new_fd };
        child.initKq() catch return error.Unexpected;

        if (remote) |out| {
            out.* = try sockaddrToAddrPort(&storage, len);
        }

        return child;
    }

    pub fn connect(self: *Tcp, ap: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (tcp_ops.isClosed(self)) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        posix.connect(self.sock, @ptrCast(&enc.storage), enc.len) catch |err| {
            const mapped = socketError(err);
            if (mapped == error.WouldBlock or mapped == error.ConnectionPending) return;
            return mapped;
        };
    }

    pub fn finishConnect(self: *Tcp) glib.net.runtime.SocketError!void {
        if (tcp_ops.isClosed(self)) return error.Closed;

        var err_code: i32 = 0;
        posix.getsockopt(self.sock, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&err_code)) catch return error.Unexpected;
        if (err_code == 0) return;
        return soErrorToSocket(err_code);
    }

    pub fn recv(self: *Tcp, buf: []u8) glib.net.runtime.SocketError!usize {
        if (tcp_ops.isClosed(self)) return error.Closed;
        return posix.recv(self.sock, buf, 0) catch |err| return socketError(err);
    }

    pub fn send(self: *Tcp, buf: []const u8) glib.net.runtime.SocketError!usize {
        if (tcp_ops.isClosed(self)) return error.Closed;
        return posix.send(self.sock, buf, 0) catch |err| return socketError(err);
    }

    pub fn localAddr(self: *Tcp) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (tcp_ops.isClosed(self)) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getsockname(self.sock, @ptrCast(&storage), &len) catch |err| return socketError(err);
        return sockaddrToAddrPort(&storage, len);
    }

    pub fn remoteAddr(self: *Tcp) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (tcp_ops.isClosed(self)) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getpeername(self.sock, @ptrCast(&storage), &len) catch |err| return socketError(err);
        return sockaddrToAddrPort(&storage, len);
    }

    pub fn setOpt(self: *Tcp, opt: glib.net.runtime.TcpOption) glib.net.runtime.SetSockOptError!void {
        if (tcp_ops.isClosed(self)) return error.Closed;
        switch (opt) {
            .socket => |s| try applySocketLevelOpt(self.sock, s),
            .tcp => |t| switch (t) {
                .no_delay => |enabled| {
                    try setSockOptBool(self.sock, posix.IPPROTO.TCP, posix.TCP.NODELAY, enabled);
                },
            },
        }
    }

    pub fn poll(self: *Tcp, want: glib.net.runtime.PollEvents, timeout: ?time.duration.Duration) glib.net.runtime.PollError!glib.net.runtime.PollEvents {
        return tcp_ops.pollCommon(self, want, timeout);
    }

    fn triggerReadWake(self: *Tcp) void {
        tcp_ops.triggerReadWake(self);
    }

    fn triggerWriteWake(self: *Tcp) void {
        tcp_ops.triggerWriteWake(self);
    }

    fn deinitKq(self: *Tcp) void {
        tcp_ops.deinitKq(self);
    }

    fn initKq(self: *Tcp) !void {
        try tcp_ops.initKq(self);
    }
};

pub const Udp = struct {
    sock: posix.socket_t = -1,
    kq: posix.fd_t = -1,
    socket_ident: usize = 0,
    read_wake_ident: usize = 0,
    write_wake_ident: usize = 0,
    closed: u8 = 0,

    read_interrupt: u8 = 0,
    write_interrupt: u8 = 0,

    const udp_ops = OpCommon(Udp);

    pub fn close(self: *Udp) void {
        if (@cmpxchgStrong(u8, &self.closed, 0, 1, .acq_rel, .acquire) != null) return;
        @atomicStore(u8, &self.read_interrupt, 1, .release);
        @atomicStore(u8, &self.write_interrupt, 1, .release);
        self.triggerReadWake();
        self.triggerWriteWake();

        if (self.sock != -1) {
            posix.close(self.sock);
            self.sock = -1;
        }
    }

    pub fn deinit(self: *Udp) void {
        self.close();
        self.deinitKq();
    }

    pub fn signal(self: *Udp, ev: glib.net.runtime.SignalEvent) void {
        if (udp_ops.isClosed(self)) return;
        udp_ops.signalCommon(self, ev);
    }

    pub fn bind(self: *Udp, ap: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (udp_ops.isClosed(self)) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        posix.bind(self.sock, @ptrCast(&enc.storage), enc.len) catch |err| return socketError(err);
    }

    pub fn connect(self: *Udp, ap: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (udp_ops.isClosed(self)) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        posix.connect(self.sock, @ptrCast(&enc.storage), enc.len) catch |err| {
            const mapped = socketError(err);
            if (mapped == error.WouldBlock or mapped == error.ConnectionPending) return;
            return mapped;
        };
    }

    pub fn finishConnect(self: *Udp) glib.net.runtime.SocketError!void {
        _ = self;
        return;
    }

    pub fn recv(self: *Udp, buf: []u8) glib.net.runtime.SocketError!usize {
        if (udp_ops.isClosed(self)) return error.Closed;
        return posix.recv(self.sock, buf, 0) catch |err| return socketError(err);
    }

    pub fn recvFrom(self: *Udp, buf: []u8, src: ?*glib.net.netip.AddrPort) glib.net.runtime.SocketError!usize {
        if (udp_ops.isClosed(self)) return error.Closed;

        if (src) |out| {
            var storage: posix.sockaddr.storage = undefined;
            var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            const n = posix.recvfrom(self.sock, buf, 0, @ptrCast(&storage), &len) catch |err| return socketError(err);
            out.* = try sockaddrToAddrPort(&storage, len);
            return n;
        }

        return posix.recv(self.sock, buf, 0) catch |err| return socketError(err);
    }

    pub fn send(self: *Udp, buf: []const u8) glib.net.runtime.SocketError!usize {
        if (udp_ops.isClosed(self)) return error.Closed;
        return posix.send(self.sock, buf, 0) catch |err| return socketError(err);
    }

    pub fn sendTo(self: *Udp, buf: []const u8, dst: glib.net.netip.AddrPort) glib.net.runtime.SocketError!usize {
        if (udp_ops.isClosed(self)) return error.Closed;
        const enc = encodeSockAddr(dst) catch |err| return encodeErrorToSocket(err);
        return posix.sendto(self.sock, buf, 0, @ptrCast(&enc.storage), enc.len) catch |err| return socketError(err);
    }

    pub fn localAddr(self: *Udp) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (udp_ops.isClosed(self)) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getsockname(self.sock, @ptrCast(&storage), &len) catch |err| return socketError(err);
        return sockaddrToAddrPort(&storage, len);
    }

    pub fn remoteAddr(self: *Udp) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (udp_ops.isClosed(self)) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getpeername(self.sock, @ptrCast(&storage), &len) catch |err| return socketError(err);
        return sockaddrToAddrPort(&storage, len);
    }

    pub fn setOpt(self: *Udp, opt: glib.net.runtime.UdpOption) glib.net.runtime.SetSockOptError!void {
        if (udp_ops.isClosed(self)) return error.Closed;
        switch (opt) {
            .socket => |s| try applySocketLevelOpt(self.sock, s),
        }
    }

    pub fn poll(self: *Udp, want: glib.net.runtime.PollEvents, timeout: ?time.duration.Duration) glib.net.runtime.PollError!glib.net.runtime.PollEvents {
        return udp_ops.pollCommon(self, want, timeout);
    }

    fn triggerReadWake(self: *Udp) void {
        udp_ops.triggerReadWake(self);
    }

    fn triggerWriteWake(self: *Udp) void {
        udp_ops.triggerWriteWake(self);
    }

    fn deinitKq(self: *Udp) void {
        udp_ops.deinitKq(self);
    }

    fn initKq(self: *Udp) !void {
        try udp_ops.initKq(self);
    }
};

fn applySocketLevelOpt(sock: posix.socket_t, opt: glib.net.runtime.SocketLevelOption) glib.net.runtime.SetSockOptError!void {
    switch (opt) {
        .reuse_addr => |enabled| {
            try setSockOptBool(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, enabled);
        },
        .reuse_port => |enabled| {
            try setSockOptBool(sock, posix.SOL.SOCKET, posix.SO.REUSEPORT, enabled);
        },
        .broadcast => |enabled| {
            try setSockOptBool(sock, posix.SOL.SOCKET, posix.SO.BROADCAST, enabled);
        },
    }
}

fn sockaddrToAddrPort(storage: *const posix.sockaddr.storage, len: posix.socklen_t) !glib.net.netip.AddrPort {
    if (len < @sizeOf(posix.sockaddr)) return error.Unexpected;
    const family = @as(*const posix.sockaddr, @ptrCast(storage)).family;

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
        error.NotSupported, error.ProtocolNotSupported => error.Unsupported,
        else => error.Unexpected,
    };
}

fn setSockOptBool(fd: posix.socket_t, level: anytype, opt: anytype, enable: bool) glib.net.runtime.SetSockOptError!void {
    const value: [4]u8 = @bitCast(@as(i32, if (enable) 1 else 0));
    posix.setsockopt(fd, level, opt, &value) catch |err| return translateSetSockOptErr(err);
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

fn remainingTimeout(started: time.instant.Time, total: time.duration.Duration) time.duration.Duration {
    const elapsed = time.instant.sub(time.instant.now(), started);
    if (elapsed <= 0) return total;
    if (elapsed >= total) return 0;
    return total - elapsed;
}

fn hasAnyWantedEvent(got: glib.net.runtime.PollEvents, want: glib.net.runtime.PollEvents) bool {
    return (want.read and got.read) or
        (want.write and got.write) or
        (want.failed and got.failed) or
        (want.hup and got.hup) or
        (want.read_interrupt and got.read_interrupt) or
        (want.write_interrupt and got.write_interrupt);
}

fn soErrorToSocket(code: i32) glib.net.runtime.SocketError {
    const e = @as(posix.E, @enumFromInt(code));
    return switch (e) {
        .ACCES => error.AccessDenied,
        .PERM => error.AccessDenied,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .AFNOSUPPORT => error.Unexpected,
        .CONNREFUSED => error.ConnectionRefused,
        // Match the shared host runtime contract for async-connect refusal via
        // `SO_ERROR` on Darwin.
        .CONNRESET => error.ConnectionRefused,
        .HOSTUNREACH => error.NetworkUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
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
    s.initKq() catch |err| {
        s.deinitKq();
        return switch (err) {
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
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
    s.initKq() catch |err| {
        s.deinitKq();
        return switch (err) {
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
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
