const std = @import("std");
const glib = @import("glib");

const posix = std.posix;
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;

const invalid_socket = ws2_32.INVALID_SOCKET;

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

fn winsockError(err: ws2_32.WinsockError) glib.net.runtime.SocketError {
    return switch (err) {
        .WSAEWOULDBLOCK => error.WouldBlock,
        .WSAEACCES => error.AccessDenied,
        .WSAEADDRINUSE => error.AddressInUse,
        .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
        .WSAEISCONN => error.AlreadyConnected,
        .WSAECONNABORTED => error.ConnectionAborted,
        .WSAEALREADY, .WSAEINPROGRESS => error.ConnectionPending,
        .WSAECONNREFUSED => error.ConnectionRefused,
        .WSAECONNRESET => error.ConnectionReset,
        .WSAETIMEDOUT => error.TimedOut,
        .WSAEMSGSIZE => error.MessageTooLong,
        .WSAEHOSTUNREACH, .WSAENETUNREACH => error.NetworkUnreachable,
        .WSAENOTCONN => error.NotConnected,
        .WSAESHUTDOWN => error.BrokenPipe,
        else => error.Unexpected,
    };
}

fn lastSocketError() glib.net.runtime.SocketError {
    return winsockError(ws2_32.WSAGetLastError());
}

fn lastSetSockOptError() glib.net.runtime.SetSockOptError {
    return switch (ws2_32.WSAGetLastError()) {
        .WSAENOPROTOOPT => error.Unsupported,
        .WSAENOTSOCK => error.Closed,
        else => error.Unexpected,
    };
}

fn closeEvent(h: ?windows.HANDLE) void {
    if (h) |ev| {
        _ = ws2_32.WSACloseEvent(ev);
    }
}

fn OpCommon(comptime Self: type) type {
    return struct {
        fn initEvents(self: *Self) !void {
            try windows.callWSAStartup();

            const sock_event = ws2_32.WSACreateEvent();
            if (@intFromPtr(sock_event) == 0) return error.SystemResources;
            errdefer closeEvent(sock_event);

            const user_event = ws2_32.WSACreateEvent();
            if (@intFromPtr(user_event) == 0) return error.SystemResources;
            errdefer closeEvent(user_event);

            if (ws2_32.WSAEventSelect(
                self.sock,
                sock_event,
                ws2_32.FD_READ | ws2_32.FD_WRITE | ws2_32.FD_ACCEPT | ws2_32.FD_CONNECT | ws2_32.FD_CLOSE,
            ) == ws2_32.SOCKET_ERROR) {
                return error.Unexpected;
            }

            self.sock_event = sock_event;
            self.user_event = user_event;
        }

        fn deinitEvents(self: *Self) void {
            closeEvent(self.sock_event);
            closeEvent(self.user_event);
            self.sock_event = null;
            self.user_event = null;
        }

        fn triggerWake(self: *Self) void {
            if (self.user_event) |ev| {
                _ = ws2_32.WSASetEvent(ev);
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

                const timeout: u32 = if (timeout_ms) |ms|
                    try remainingTimeoutMs(started.?, ms)
                else
                    windows.INFINITE;

                var handles = [_]windows.HANDLE{ self.sock_event.?, self.user_event.? };
                const rc = ws2_32.WSAWaitForMultipleEvents(
                    @intCast(handles.len),
                    &handles,
                    windows.FALSE,
                    timeout,
                    windows.FALSE,
                );

                switch (rc) {
                    windows.WAIT_TIMEOUT => return error.TimedOut,
                    windows.WAIT_FAILED => return error.Unexpected,
                    windows.WAIT_OBJECT_0 => {
                        var evs: ws2_32.WSANETWORKEVENTS = undefined;
                        if (ws2_32.WSAEnumNetworkEvents(self.sock, self.sock_event.?, &evs) == ws2_32.SOCKET_ERROR) {
                            return error.Unexpected;
                        }

                        if ((evs.lNetworkEvents & ws2_32.FD_ACCEPT) != 0) {
                            out.read = true;
                            if (evs.iErrorCode[ws2_32.FD_ACCEPT_BIT] != 0) out.failed = true;
                        }
                        if ((evs.lNetworkEvents & ws2_32.FD_READ) != 0) {
                            out.read = true;
                            if (evs.iErrorCode[ws2_32.FD_READ_BIT] != 0) out.failed = true;
                        }
                        if ((evs.lNetworkEvents & ws2_32.FD_CONNECT) != 0) {
                            out.write = true;
                            if (evs.iErrorCode[ws2_32.FD_CONNECT_BIT] != 0) out.failed = true;
                        }
                        if ((evs.lNetworkEvents & ws2_32.FD_WRITE) != 0) {
                            out.write = true;
                            if (evs.iErrorCode[ws2_32.FD_WRITE_BIT] != 0) out.failed = true;
                        }
                        if ((evs.lNetworkEvents & ws2_32.FD_CLOSE) != 0) {
                            out.hup = true;
                            if (evs.iErrorCode[ws2_32.FD_CLOSE_BIT] != 0) out.failed = true;
                        }
                    },
                    windows.WAIT_OBJECT_0 + 1 => {
                        _ = ws2_32.WSAResetEvent(self.user_event.?);
                        if (takeReadInterrupt(self, want)) out.read_interrupt = true;
                        if (takeWriteInterrupt(self, want)) out.write_interrupt = true;
                    },
                    else => return error.Unexpected,
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
    sock: posix.socket_t = invalid_socket,
    sock_event: ?windows.HANDLE = null,
    user_event: ?windows.HANDLE = null,
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

        if (self.sock != invalid_socket) {
            windows.closesocket(self.sock) catch {};
            self.sock = invalid_socket;
        }
        self.deinitEvents();
    }

    pub fn shutdown(self: *Tcp, how: glib.net.runtime.ShutdownHow) glib.net.runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const wsa_how: i32 = switch (how) {
            .read => ws2_32.SD_RECEIVE,
            .write => ws2_32.SD_SEND,
            .both => ws2_32.SD_BOTH,
        };
        if (ws2_32.shutdown(self.sock, wsa_how) == ws2_32.SOCKET_ERROR) {
            return lastSocketError();
        }
    }

    pub fn signal(self: *Tcp, ev: glib.net.runtime.SignalEvent) void {
        if (self.closed) return;
        tcp_ops.signalCommon(self, ev);
    }

    pub fn bind(self: *Tcp, ap: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        if (windows.bind(self.sock, @ptrCast(&enc.storage), enc.len) == ws2_32.SOCKET_ERROR) {
            return lastSocketError();
        }
    }

    pub fn listen(self: *Tcp, backlog: u31) glib.net.runtime.SocketError!void {
        if (self.closed) return error.Closed;
        if (windows.listen(self.sock, backlog) == ws2_32.SOCKET_ERROR) {
            return lastSocketError();
        }
    }

    pub fn accept(self: *Tcp, remote: ?*glib.net.netip.AddrPort) glib.net.runtime.SocketError!Tcp {
        if (self.closed) return error.Closed;

        var storage: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

        const new_sock = windows.accept(self.sock, @ptrCast(&storage), &len);
        if (new_sock == invalid_socket) return lastSocketError();
        errdefer windows.closesocket(new_sock) catch {};

        setNoSigPipe(new_sock);

        var child: Tcp = .{ .sock = new_sock };
        child.initEvents() catch |err| return switch (err) {
            error.SystemResources => error.Unexpected,
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
        if (ws2_32.connect(self.sock, @ptrCast(&enc.storage), @intCast(enc.len)) == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAEWOULDBLOCK, .WSAEALREADY, .WSAEINPROGRESS => {},
                else => |err| winsockError(err),
            };
        }
    }

    pub fn finishConnect(self: *Tcp) glib.net.runtime.SocketError!void {
        if (self.closed) return error.Closed;

        var err_code: i32 = 0;
        var len: i32 = @sizeOf(i32);
        if (ws2_32.getsockopt(self.sock, ws2_32.SOL.SOCKET, ws2_32.SO.ERROR, @ptrCast(&err_code), &len) == ws2_32.SOCKET_ERROR) {
            return error.Unexpected;
        }
        if (err_code == 0) return;
        return winsockErrorToSocket(err_code);
    }

    pub fn recv(self: *Tcp, buf: []u8) glib.net.runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        const n = ws2_32.recv(self.sock, buf.ptr, @intCast(buf.len), 0);
        if (n == ws2_32.SOCKET_ERROR) return lastSocketError();
        return @intCast(n);
    }

    pub fn send(self: *Tcp, buf: []const u8) glib.net.runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        const n = ws2_32.send(self.sock, buf.ptr, @intCast(buf.len), 0);
        if (n == ws2_32.SOCKET_ERROR) return lastSocketError();
        return @intCast(n);
    }

    pub fn localAddr(self: *Tcp) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (self.closed) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: i32 = @sizeOf(posix.sockaddr.storage);
        if (ws2_32.getsockname(self.sock, @ptrCast(&storage), &len) == ws2_32.SOCKET_ERROR) return error.Unexpected;
        return sockaddrToAddrPort(&storage, @intCast(len));
    }

    pub fn remoteAddr(self: *Tcp) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (self.closed) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: i32 = @sizeOf(posix.sockaddr.storage);
        if (ws2_32.getpeername(self.sock, @ptrCast(&storage), &len) == ws2_32.SOCKET_ERROR) {
            return lastSocketError();
        }
        return sockaddrToAddrPort(&storage, @intCast(len));
    }

    pub fn setOpt(self: *Tcp, opt: glib.net.runtime.TcpOption) glib.net.runtime.SetSockOptError!void {
        if (self.closed) return error.Closed;
        switch (opt) {
            .socket => |s| try applySocketLevelOpt(self.sock, s),
            .tcp => |t| switch (t) {
                .no_delay => |enabled| {
                    const v: i32 = if (enabled) 1 else 0;
                    if (ws2_32.setsockopt(self.sock, ws2_32.IPPROTO.TCP, ws2_32.TCP.NODELAY, @ptrCast(&v), @sizeOf(i32)) == ws2_32.SOCKET_ERROR) {
                        return lastSetSockOptError();
                    }
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

    fn deinitEvents(self: *Tcp) void {
        tcp_ops.deinitEvents(self);
    }

    fn initEvents(self: *Tcp) !void {
        try tcp_ops.initEvents(self);
    }
};

pub const Udp = struct {
    sock: posix.socket_t = invalid_socket,
    sock_event: ?windows.HANDLE = null,
    user_event: ?windows.HANDLE = null,
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

        if (self.sock != invalid_socket) {
            windows.closesocket(self.sock) catch {};
            self.sock = invalid_socket;
        }
        self.deinitEvents();
    }

    pub fn signal(self: *Udp, ev: glib.net.runtime.SignalEvent) void {
        if (self.closed) return;
        udp_ops.signalCommon(self, ev);
    }

    pub fn bind(self: *Udp, ap: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        if (windows.bind(self.sock, @ptrCast(&enc.storage), enc.len) == ws2_32.SOCKET_ERROR) {
            return lastSocketError();
        }
    }

    pub fn connect(self: *Udp, ap: glib.net.netip.AddrPort) glib.net.runtime.SocketError!void {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(ap) catch |err| return encodeErrorToSocket(err);
        if (ws2_32.connect(self.sock, @ptrCast(&enc.storage), @intCast(enc.len)) == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAEWOULDBLOCK, .WSAEALREADY, .WSAEINPROGRESS => {},
                else => |err| winsockError(err),
            };
        }
    }

    pub fn finishConnect(self: *Udp) glib.net.runtime.SocketError!void {
        _ = self;
    }

    pub fn recv(self: *Udp, buf: []u8) glib.net.runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        const n = ws2_32.recv(self.sock, buf.ptr, @intCast(buf.len), 0);
        if (n == ws2_32.SOCKET_ERROR) return lastSocketError();
        return @intCast(n);
    }

    pub fn recvFrom(self: *Udp, buf: []u8, src: ?*glib.net.netip.AddrPort) glib.net.runtime.SocketError!usize {
        if (self.closed) return error.Closed;

        if (src) |out| {
            var storage: posix.sockaddr.storage = undefined;
            var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            const n = windows.recvfrom(self.sock, buf.ptr, buf.len, 0, @ptrCast(&storage), &len);
            if (n == ws2_32.SOCKET_ERROR) return lastSocketError();
            out.* = try sockaddrToAddrPort(&storage, len);
            return @intCast(n);
        }

        const n = ws2_32.recv(self.sock, buf.ptr, @intCast(buf.len), 0);
        if (n == ws2_32.SOCKET_ERROR) return lastSocketError();
        return @intCast(n);
    }

    pub fn send(self: *Udp, buf: []const u8) glib.net.runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        const n = ws2_32.send(self.sock, buf.ptr, @intCast(buf.len), 0);
        if (n == ws2_32.SOCKET_ERROR) return lastSocketError();
        return @intCast(n);
    }

    pub fn sendTo(self: *Udp, buf: []const u8, dst: glib.net.netip.AddrPort) glib.net.runtime.SocketError!usize {
        if (self.closed) return error.Closed;
        const enc = encodeSockAddr(dst) catch |err| return encodeErrorToSocket(err);
        const n = windows.sendto(self.sock, buf.ptr, buf.len, 0, @ptrCast(&enc.storage), enc.len);
        if (n == ws2_32.SOCKET_ERROR) return lastSocketError();
        return @intCast(n);
    }

    pub fn localAddr(self: *Udp) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (self.closed) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: i32 = @sizeOf(posix.sockaddr.storage);
        if (ws2_32.getsockname(self.sock, @ptrCast(&storage), &len) == ws2_32.SOCKET_ERROR) return error.Unexpected;
        return sockaddrToAddrPort(&storage, @intCast(len));
    }

    pub fn remoteAddr(self: *Udp) glib.net.runtime.SocketError!glib.net.netip.AddrPort {
        if (self.closed) return error.Closed;
        var storage: posix.sockaddr.storage = undefined;
        var len: i32 = @sizeOf(posix.sockaddr.storage);
        if (ws2_32.getpeername(self.sock, @ptrCast(&storage), &len) == ws2_32.SOCKET_ERROR) {
            return lastSocketError();
        }
        return sockaddrToAddrPort(&storage, @intCast(len));
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

    fn deinitEvents(self: *Udp) void {
        udp_ops.deinitEvents(self);
    }

    fn initEvents(self: *Udp) !void {
        try udp_ops.initEvents(self);
    }
};

fn applySocketLevelOpt(sock: posix.socket_t, opt: glib.net.runtime.SocketLevelOption) glib.net.runtime.SetSockOptError!void {
    switch (opt) {
        .reuse_addr => |enabled| {
            const v: i32 = if (enabled) 1 else 0;
            if (ws2_32.setsockopt(sock, ws2_32.SOL.SOCKET, ws2_32.SO.REUSEADDR, @ptrCast(&v), @sizeOf(i32)) == ws2_32.SOCKET_ERROR) {
                return lastSetSockOptError();
            }
        },
        .reuse_port => |enabled| {
            if (!@hasDecl(posix.SO, "REUSEPORT")) return error.Unsupported;
            _ = enabled;
            return error.Unsupported;
        },
        .broadcast => |enabled| {
            const v: i32 = if (enabled) 1 else 0;
            if (ws2_32.setsockopt(sock, ws2_32.SOL.SOCKET, ws2_32.SO.BROADCAST, @ptrCast(&v), @sizeOf(i32)) == ws2_32.SOCKET_ERROR) {
                return lastSetSockOptError();
            }
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

fn translateSetSockOptErr(err: posix.SetSockOptError) glib.net.runtime.SetSockOptError {
    return switch (err) {
        error.Closed => error.Closed,
        error.NotSupported, error.ProtocolNotSupported => error.Unsupported,
        else => error.Unexpected,
    };
}

fn winsockErrorToSocket(code: i32) glib.net.runtime.SocketError {
    const e = @as(ws2_32.WinsockError, @enumFromInt(@as(u16, @intCast(code))));
    return switch (e) {
        .WSAEACCES => error.AccessDenied,
        .WSAEADDRINUSE => error.AddressInUse,
        .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
        .WSAECONNREFUSED => error.ConnectionRefused,
        .WSAECONNRESET => error.ConnectionReset,
        .WSAEHOSTUNREACH, .WSAENETUNREACH => error.NetworkUnreachable,
        .WSAETIMEDOUT => error.TimedOut,
        .WSAEISCONN => error.AlreadyConnected,
        .WSAENOTCONN => error.NotConnected,
        .WSAESHUTDOWN => error.BrokenPipe,
        .WSAEMSGSIZE => error.MessageTooLong,
        else => error.Unexpected,
    };
}

pub fn tcp(domain: glib.net.runtime.Domain) glib.net.runtime.CreateError!Tcp {
    const family = socketDomain(domain);
    const sock = posix.socket(family, posix.SOCK.STREAM, 0) catch |err| return translateCreateErr(err);
    errdefer windows.closesocket(sock) catch {};

    setNoSigPipe(sock);

    var s: Tcp = .{ .sock = sock };
    s.initEvents() catch |err| {
        s.deinitEvents();
        return switch (err) {
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };

    return s;
}

pub fn udp(domain: glib.net.runtime.Domain) glib.net.runtime.CreateError!Udp {
    const family = socketDomain(domain);
    const sock = posix.socket(family, posix.SOCK.DGRAM, 0) catch |err| return translateCreateErr(err);
    errdefer windows.closesocket(sock) catch {};

    setNoSigPipe(sock);

    var s: Udp = .{ .sock = sock };
    s.initEvents() catch |err| {
        s.deinitEvents();
        return switch (err) {
            error.SystemResources => error.SystemResources,
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
