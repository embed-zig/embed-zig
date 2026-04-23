const std = @import("std");
const net_mod = @import("net");
const runtime = net_mod.runtime;
const netip = net_mod.netip;

const posix = std.posix;
const system = posix.system;
const EV = std.c.EV;
const NOTE = std.c.NOTE;
const EVFILT = std.c.EVFILT;

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

fn parseScopeId(addr: netip.Addr) EncodeSockAddrError!u32 {
    const zone = addr.zone[0..addr.zone_len];
    if (zone.len == 0) return 0;

    var scope_id: u32 = 0;
    for (zone) |c| {
        if (c < '0' or c > '9') return error.InvalidScopeId;
        scope_id = mulAddU32(scope_id, 10, c - '0') catch return error.InvalidScopeId;
    }
    return scope_id;
}

fn encodeSockAddr(addr_port: netip.AddrPort) EncodeSockAddrError!EncodedSockAddr {
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

fn encodeErrorToSocket(err: EncodeSockAddrError) runtime.SocketError {
    return switch (err) {
        error.InvalidAddress => error.Unexpected,
        error.InvalidScopeId => error.Unexpected,
    };
}

fn socketDomain(domain: runtime.Domain) u32 {
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
    const enable: std.c.int = 1;
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, std.mem.asBytes(&enable)) catch {};
}

fn wakeUserEvent(ident: usize) posix.Kevent {
    return .{
        .ident = ident,
        .filter = system.EVFILT.USER,
        .flags = EV.ADD | NOTE.TRIGGER,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
}

fn OpCommon(comptime Self: type) type {
    return struct {
        fn userIdent(self: *const Self) usize {
            return @intFromPtr(self);
        }

        fn initKq(self: *Self) !void {
            self.kq = try posix.kqueue();

            const ident = userIdent(self);

            const user_add = [2]posix.Kevent{
                .{
                    .ident = ident,
                    .filter = system.EVFILT.USER,
                    .flags = EV.ADD | EV.CLEAR,
                    .fflags = NOTE.FFNOP,
                    .data = 0,
                    .udata = 0,
                },
                .{
                    .ident = self.sock,
                    .filter = system.EVFILT.READ,
                    .flags = EV.ADD | EV.CLEAR,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                },
            };
            _ = try posix.kevent(self.kq, &user_add, &.{}, null);

            const write_add = posix.Kevent{
                .ident = self.sock,
                .filter = system.EVFILT.WRITE,
                .flags = EV.ADD | EV.CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            _ = try posix.kevent(self.kq, &.{write_add}, &.{}, null);
        }

        fn deinitKq(self: *Self) void {
            if (self.kq != -1) {
                posix.close(self.kq);
                self.kq = -1;
            }
        }

        fn triggerWake(self: *Self) void {
            if (self.kq == -1) return;
            const ev = wakeUserEvent(self.userIdent());
            posix.kevent(self.kq, &.{ev}, &.{}, null) catch {};
        }

        fn signalCommon(self: *Self, ev: runtime.SignalEvent) void {
            switch (ev) {
                .read_interrupt => {
                    self.read_interrupt = true;
                    self.triggerWake();
                },
                .write_interrupt => {
                    self.write_interrupt = true;
                    self.triggerWake();
                },
            }
        }

        fn pollCommon(self: *Self, want: runtime.PollEvents, timeout_ms: ?u32) runtime.PollError!runtime.PollEvents {
            if (self.closed) return error.Closed;
            if (self.kq == -1) return error.Unexpected;

            var ts: posix.timespec = undefined;
            const timeout_ptr: ?*const posix.timespec = blk: {
                const t = timeout_ms orelse break :blk null;
                if (t == 0) break :blk &.{ .sec = 0, .nsec = 0 };
                ts = .{
                    .sec = @as(isize, @intCast(@divFloor(t, 1000))),
                    .nsec = @as(isize, @intCast(@as(u64, @mod(t, 1000)) * std.time.ns_per_ms)),
                };
                break :blk &ts;
            };

            var out = runtime.PollEvents{};

            poll_loop: while (true) {
                if (self.closed) return error.Closed;

                var evs: [8]posix.Kevent = undefined;
                const n = try posix.kevent(self.kq, &.{}, &evs, timeout_ptr);

                if (n == 0) {
                    if (timeout_ms != null) return error.TimedOut;
                    continue;
                }

                for (evs[0..n]) |kev| {
                    if (kev.ident == self.userIdent() and kev.filter == system.EVFILT.USER) {
                        if (self.read_interrupt) out.read_interrupt = true;
                        if (self.write_interrupt) out.write_interrupt = true;
                        continue;
                    }

                    if (kev.ident == @as(usize, @intCast(self.sock))) {
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

                if (want.read and !out.read) continue :poll_loop;
                if (want.write and !out.write) continue :poll_loop;
                if (want.failed and !out.failed) continue :poll_loop;
                if (want.hup and !out.hup) continue :poll_loop;
                if (want.read_interrupt and !out.read_interrupt) continue :poll_loop;
                if (want.write_interrupt and !out.write_interrupt) continue :poll_loop;

                return out;
            }
        }
    };
}

pub const Tcp = struct {
    sock: posix.socket_t = -1,
    kq: posix.fd_t = -1,
    closed: bool = false,

    read_interrupt: bool = false,
    write_interrupt: bool = false,

    const tcp_ops = OpCommon(Tcp);

    pub fn close(self: *Tcp) void {
        if (self.closed) return;
        self.closed = true;
        self.read_interrupt = true;
        self.write_interrupt = true;
        self.triggerWake();

        if (self.sock != -1) {
            posix.close(self.sock);
            self.sock = -1;
        }
        self.deinitKq();
    }

    pub fn shutdown(self: *Tcp, how: runtime.ShutdownHow) runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const posix_how: posix.ShutdownHow = switch (how) {
            .read => .RECV,
            .write => .SEND,
            .both => .BOTH,
        };
        posix.shutdown(self.sock, posix_how) catch |err| return switch (err) {
            error.SocketNotConnected => error.NotConnected,
            else => error.Unexpected,
        };
    }

    pub fn signal(self: *Tcp, ev: runtime.SignalEvent) void {
        if (self.closed) return;
        tcp_ops.signalCommon(self, ev);
    }

    pub fn bind(self: *Tcp, ap: netip.AddrPort) runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        posix.bind(self.sock, @ptrCast(&enc.storage), enc.len) catch |err| return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.AddressFamilyNotSupported => error.Unexpected,
            error.AddressInUse => error.AddressInUse,
            error.AddressNotAvailable => error.AddressNotAvailable,
            error.AlreadyBound => error.Unexpected,
            error.BadFileDescriptor => error.Unexpected,
            error.FileDescriptorNotASocket => error.Unexpected,
            error.InvalidCharacter => error.Unexpected,
            error.NameTooLong => error.Unexpected,
            error.FileNotFound => error.Unexpected,
            error.NotDir => error.Unexpected,
            error.ReadOnlyFileSystem => error.Unexpected,
            error.SystemResources => error.Unexpected,
            error.Unexpected => error.Unexpected,
        };
    }

    pub fn listen(self: *Tcp, backlog: u31) runtime.SocketError!void {
        if (self.closed) return error.Closed;
        posix.listen(self.sock, backlog) catch |err| return switch (err) {
            error.AddressInUse => error.AddressInUse,
            error.FileDescriptorNotASocket => error.Unexpected,
            error.AlreadyConnected => error.AlreadyConnected,
            error.SocketNotBound => error.Unexpected,
            error.BadFileDescriptor => error.Unexpected,
            error.FileBusy => error.Unexpected,
            error.SystemResources => error.Unexpected,
            error.Unexpected => error.Unexpected,
        };
    }

    pub fn accept(self: *Tcp, remote: ?*netip.AddrPort) runtime.SocketError!Tcp {
        if (self.closed) return error.Closed;

        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

        const new_fd = posix.accept(self.sock, @ptrCast(&storage), &len, 0) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            error.ConnectionAborted => error.ConnectionAborted,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            => error.Unexpected,
            else => error.Unexpected,
        };
        errdefer posix.close(new_fd);

        setNonBlocking(new_fd) catch return error.Unexpected;
        setNoSigPipe(new_fd);

        var child: Tcp = .{ .sock = new_fd };
        try child.initKq();

        if (remote) |out| {
            out.* = try sockaddrToAddrPort(&storage, len);
        }

        return child;
    }

    pub fn connect(self: *Tcp, ap: netip.AddrPort) runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        posix.connect(self.sock, @ptrCast(&enc.storage), enc.len) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionPending => return,
            error.AccessDenied => error.AccessDenied,
            error.AddressFamilyNotSupported => error.Unexpected,
            error.AddressInUse => error.AddressInUse,
            error.AddressNotAvailable => error.AddressNotAvailable,
            error.AlreadyConnected => error.AlreadyConnected,
            error.BadFileDescriptor => error.Unexpected,
            error.ConnectionRefused => error.ConnectionRefused,
            error.ConnectionReset => error.ConnectionReset,
            error.ConnectionTimedOut => error.TimedOut,
            error.HostUnreachable => error.NetworkUnreachable,
            error.NetUnreachable => error.NetworkUnreachable,
            error.NetworkSubsystemFailed => error.Unexpected,
            error.FileDescriptorNotASocket => error.Unexpected,
            error.NotSocket => error.Unexpected,
            error.ProtocolNotSupported => error.Unexpected,
            error.WrongProtocolForSocket => error.Unexpected,
            error.SystemResources => error.Unexpected,
            error.Unexpected => error.Unexpected,
        };
    }

    pub fn finishConnect(self: *Tcp) runtime.SocketError!void {
        if (self.closed) return error.Closed;

        var err_code: i32 = 0;
        posix.getsockopt(self.sock, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&err_code)) catch return error.Unexpected;
        if (err_code == 0) return;
        return soErrorToSocket(err_code);
    }

    pub fn recv(self: *Tcp, buf: []u8) runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        return posix.recv(self.sock, buf, 0) catch |err| return switch (err) {
            error.WouldBlock => error.WouldBlock,
            error.ConnectionReset => error.ConnectionReset,
            error.ConnectionTimedOut => error.TimedOut,
            error.MessageTooLong => error.MessageTooLong,
            error.NotConnected => error.NotConnected,
            error.BrokenPipe => error.BrokenPipe,
            error.SystemResources => error.Unexpected,
            error.SocketNotConnected => error.NotConnected,
            error.Unexpected => error.Unexpected,
        };
    }

    pub fn send(self: *Tcp, buf: []const u8) runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        return posix.send(self.sock, buf, 0) catch |err| return switch (err) {
            error.WouldBlock => error.WouldBlock,
            error.AccessDenied => error.AccessDenied,
            error.BrokenPipe => error.BrokenPipe,
            error.ConnectionReset => error.ConnectionReset,
            error.MessageTooLong => error.MessageTooLong,
            error.NetworkUnreachable => error.NetworkUnreachable,
            error.NotOpenForWriting => error.Unexpected,
            error.Unexpected => error.Unexpected,
            error.SystemResources => error.Unexpected,
            error.SocketNotConnected => error.NotConnected,
        };
    }

    pub fn localAddr(self: *Tcp) runtime.SocketError!netip.AddrPort {
        if (self.closed) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getsockname(self.sock, @ptrCast(&storage), &len) catch return error.Unexpected;
        return sockaddrToAddrPort(&storage, len);
    }

    pub fn remoteAddr(self: *Tcp) runtime.SocketError!netip.AddrPort {
        if (self.closed) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getpeername(self.sock, @ptrCast(&storage), &len) catch |err| return switch (err) {
            error.NotConnected => error.NotConnected,
            else => error.Unexpected,
        };
        return sockaddrToAddrPort(&storage, len);
    }

    pub fn setOpt(self: *Tcp, opt: runtime.TcpOption) runtime.SetSockOptError!void {
        if (self.closed) return error.Closed;
        switch (opt) {
            .socket => |s| try applySocketLevelOpt(self.sock, s),
            .tcp => |t| switch (t) {
                .no_delay => |enabled| {
                    const v: std.c.int = if (enabled) 1 else 0;
                    posix.setsockopt(self.sock, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&v)) catch |err| return translateSetSockOptErr(err);
                },
            },
        }
    }

    pub fn poll(self: *Tcp, want: runtime.PollEvents, timeout_ms: ?u32) runtime.PollError!runtime.PollEvents {
        return tcp_ops.pollCommon(self, want, timeout_ms);
    }

    fn triggerWake(self: *Tcp) void {
        tcp_ops.triggerWake(self);
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
    closed: bool = false,

    read_interrupt: bool = false,
    write_interrupt: bool = false,

    const udp_ops = OpCommon(Udp);

    pub fn close(self: *Udp) void {
        if (self.closed) return;
        self.closed = true;
        self.read_interrupt = true;
        self.write_interrupt = true;
        self.triggerWake();

        if (self.sock != -1) {
            posix.close(self.sock);
            self.sock = -1;
        }
        self.deinitKq();
    }

    pub fn signal(self: *Udp, ev: runtime.SignalEvent) void {
        if (self.closed) return;
        udp_ops.signalCommon(self, ev);
    }

    pub fn bind(self: *Udp, ap: netip.AddrPort) runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        posix.bind(self.sock, @ptrCast(&enc.storage), enc.len) catch |err| return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.AddressFamilyNotSupported => error.Unexpected,
            error.AddressInUse => error.AddressInUse,
            error.AddressNotAvailable => error.AddressNotAvailable,
            error.AlreadyBound => error.Unexpected,
            error.BadFileDescriptor => error.Unexpected,
            error.FileDescriptorNotASocket => error.Unexpected,
            error.InvalidCharacter => error.Unexpected,
            error.NameTooLong => error.Unexpected,
            error.FileNotFound => error.Unexpected,
            error.NotDir => error.Unexpected,
            error.ReadOnlyFileSystem => error.Unexpected,
            error.SystemResources => error.Unexpected,
            error.Unexpected => error.Unexpected,
        };
    }

    pub fn connect(self: *Udp, ap: netip.AddrPort) runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        posix.connect(self.sock, @ptrCast(&enc.storage), enc.len) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionPending => return,
            error.AccessDenied => error.AccessDenied,
            error.AddressFamilyNotSupported => error.Unexpected,
            error.AddressInUse => error.AddressInUse,
            error.AddressNotAvailable => error.AddressNotAvailable,
            error.AlreadyConnected => error.AlreadyConnected,
            error.BadFileDescriptor => error.Unexpected,
            error.ConnectionRefused => error.ConnectionRefused,
            error.ConnectionReset => error.ConnectionReset,
            error.ConnectionTimedOut => error.TimedOut,
            error.HostUnreachable => error.NetworkUnreachable,
            error.NetUnreachable => error.NetworkUnreachable,
            error.NetworkSubsystemFailed => error.Unexpected,
            error.FileDescriptorNotASocket => error.Unexpected,
            error.NotSocket => error.Unexpected,
            error.ProtocolNotSupported => error.Unexpected,
            error.WrongProtocolForSocket => error.Unexpected,
            error.SystemResources => error.Unexpected,
            error.Unexpected => error.Unexpected,
        };
    }

    pub fn finishConnect(self: *Udp) runtime.SocketError!void {
        _ = self;
        return;
    }

    pub fn recv(self: *Udp, buf: []u8) runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        return posix.recv(self.sock, buf, 0) catch |err| return switch (err) {
            error.WouldBlock => error.WouldBlock,
            error.ConnectionReset => error.ConnectionReset,
            error.ConnectionTimedOut => error.TimedOut,
            error.MessageTooLong => error.MessageTooLong,
            error.NotConnected => error.NotConnected,
            error.BrokenPipe => error.BrokenPipe,
            error.SystemResources => error.Unexpected,
            error.SocketNotConnected => error.NotConnected,
            error.Unexpected => error.Unexpected,
        };
    }

    pub fn recvFrom(self: *Udp, buf: []u8, src: ?*netip.AddrPort) runtime.SocketError!usize {
        if (self.closed) return error.Closed;

        if (src) |out| {
            var storage: posix.sockaddr.storage = undefined;
            var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            const n = posix.recvfrom(self.sock, buf, 0, @ptrCast(&storage), &len) catch |err| return switch (err) {
                error.WouldBlock => error.WouldBlock,
                error.ConnectionReset => error.ConnectionReset,
                error.ConnectionTimedOut => error.TimedOut,
                error.MessageTooLong => error.MessageTooLong,
                error.NotConnected => error.NotConnected,
                error.BrokenPipe => error.BrokenPipe,
                error.SystemResources => error.Unexpected,
                error.SocketNotConnected => error.NotConnected,
                error.Unexpected => error.Unexpected,
            };
            out.* = try sockaddrToAddrPort(&storage, len);
            return n;
        }

        return posix.recv(self.sock, buf, 0) catch |err| return switch (err) {
            error.WouldBlock => error.WouldBlock,
            error.ConnectionReset => error.ConnectionReset,
            error.ConnectionTimedOut => error.TimedOut,
            error.MessageTooLong => error.MessageTooLong,
            error.NotConnected => error.NotConnected,
            error.BrokenPipe => error.BrokenPipe,
            error.SystemResources => error.Unexpected,
            error.SocketNotConnected => error.NotConnected,
            error.Unexpected => error.Unexpected,
        };
    }

    pub fn send(self: *Udp, buf: []const u8) runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        return posix.send(self.sock, buf, 0) catch |err| return switch (err) {
            error.WouldBlock => error.WouldBlock,
            error.AccessDenied => error.AccessDenied,
            error.BrokenPipe => error.BrokenPipe,
            error.ConnectionReset => error.ConnectionReset,
            error.MessageTooLong => error.MessageTooLong,
            error.NetworkUnreachable => error.NetworkUnreachable,
            error.NotOpenForWriting => error.Unexpected,
            error.Unexpected => error.Unexpected,
            error.SystemResources => error.Unexpected,
            error.SocketNotConnected => error.NotConnected,
        };
    }

    pub fn sendTo(self: *Udp, buf: []const u8, dst: netip.AddrPort) runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(dst) catch |err| return encodeErrorToSocket(err);
        return posix.sendto(self.sock, buf, 0, @ptrCast(&enc.storage), enc.len) catch |err| return switch (err) {
            error.WouldBlock => error.WouldBlock,
            error.AccessDenied => error.AccessDenied,
            error.BrokenPipe => error.BrokenPipe,
            error.ConnectionReset => error.ConnectionReset,
            error.MessageTooLong => error.MessageTooLong,
            error.NetworkUnreachable => error.NetworkUnreachable,
            error.NotOpenForWriting => error.Unexpected,
            error.Unexpected => error.Unexpected,
            error.SystemResources => error.Unexpected,
            error.SocketNotConnected => error.NotConnected,
        };
    }

    pub fn localAddr(self: *Udp) runtime.SocketError!netip.AddrPort {
        if (self.closed) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getsockname(self.sock, @ptrCast(&storage), &len) catch return error.Unexpected;
        return sockaddrToAddrPort(&storage, len);
    }

    pub fn remoteAddr(self: *Udp) runtime.SocketError!netip.AddrPort {
        if (self.closed) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getpeername(self.sock, @ptrCast(&storage), &len) catch |err| return switch (err) {
            error.NotConnected => error.NotConnected,
            else => error.Unexpected,
        };
        return sockaddrToAddrPort(&storage, len);
    }

    pub fn setOpt(self: *Udp, opt: runtime.UdpOption) runtime.SetSockOptError!void {
        if (self.closed) return error.Closed;
        switch (opt) {
            .socket => |s| try applySocketLevelOpt(self.sock, s),
        }
    }

    pub fn poll(self: *Udp, want: runtime.PollEvents, timeout_ms: ?u32) runtime.PollError!runtime.PollEvents {
        return udp_ops.pollCommon(self, want, timeout_ms);
    }

    fn triggerWake(self: *Udp) void {
        udp_ops.triggerWake(self);
    }

    fn deinitKq(self: *Udp) void {
        udp_ops.deinitKq(self);
    }

    fn initKq(self: *Udp) !void {
        try udp_ops.initKq(self);
    }
};

fn applySocketLevelOpt(sock: posix.socket_t, opt: runtime.SocketLevelOption) runtime.SetSockOptError!void {
    switch (opt) {
        .reuse_addr => |enabled| {
            const v: std.c.int = if (enabled) 1 else 0;
            posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&v)) catch |err| return translateSetSockOptErr(err);
        },
        .reuse_port => |enabled| {
            const v: std.c.int = if (enabled) 1 else 0;
            posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEPORT, std.mem.asBytes(&v)) catch |err| return translateSetSockOptErr(err);
        },
        .broadcast => |enabled| {
            const v: std.c.int = if (enabled) 1 else 0;
            posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&v)) catch |err| return translateSetSockOptErr(err);
        },
    }
}

fn sockaddrToAddrPort(storage: *const posix.sockaddr.storage, len: posix.socklen_t) !netip.AddrPort {
    if (len < @sizeOf(posix.sockaddr)) return error.Unexpected;
    const family = std.mem.readIntNative(u16, std.mem.asBytes(&@as(*const posix.sockaddr, @ptrCast(storage)).family));

    if (family == posix.AF.INET) {
        if (len < @sizeOf(posix.sockaddr.in)) return error.Unexpected;
        const sa: *const posix.sockaddr.in = @ptrCast(@alignCast(storage));
        const port = std.mem.bigToNative(u16, sa.port);
        const addr_bytes: *align(1) const [4]u8 = @ptrCast(&sa.addr);
        return netip.AddrPort.from4(addr_bytes.*, port);
    }

    if (family == posix.AF.INET6) {
        if (len < @sizeOf(posix.sockaddr.in6)) return error.Unexpected;
        const sa: *const posix.sockaddr.in6 = @ptrCast(@alignCast(storage));
        const port = std.mem.bigToNative(u16, sa.port);
        return netip.AddrPort.from16(sa.addr, port);
    }

    return error.Unexpected;
}

fn translateSetSockOptErr(err: posix.SetSockOptError) runtime.SetSockOptError {
    return switch (err) {
        error.Closed => error.Closed,
        error.NotSupported, error.ProtocolNotSupported => error.Unsupported,
        else => error.Unexpected,
    };
}

fn soErrorToSocket(code: i32) runtime.SocketError {
    const e = @as(posix.E, @enumFromInt(code));
    return switch (e) {
        .ACCES => error.AccessDenied,
        .PERM => error.AccessDenied,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .AFNOSUPPORT => error.Unexpected,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionReset,
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

pub fn tcp(domain: runtime.Domain) runtime.CreateError!Tcp {
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

pub fn udp(domain: runtime.Domain) runtime.CreateError!Udp {
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

fn translateCreateErr(err: posix.SocketError) runtime.CreateError {
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
