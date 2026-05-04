const glib = @import("glib");
const binding = @import("binding.zig");
const Time = @import("../time/instant.zig");
const heap_binding = @import("../std/heap/binding.zig");
const Condition = @import("../std/thread/Condition.zig");
const Mutex = @import("../std/thread/Mutex.zig");

const runtime = glib.net.runtime;
const netip = glib.net.netip;
const max_udp_payload_len = glib.std.math.maxInt(u16);

const State = struct {
    conn: ?*binding.netconn,
    mutex: Mutex = .{},
    condition: Condition = .{},
    closed: bool = false,
    read_ready_count: usize = 0,
    write_ready: bool = true,
    failed: bool = false,
    read_interrupt: bool = false,
    write_interrupt: bool = false,
    pending_recv: ?*binding.netbuf = null,
    pending_recv_offset: usize = 0,

    fn create(conn: *binding.netconn) error{OutOfMemory}!*State {
        const raw = heap_binding.espz_heap_caps_malloc(@sizeOf(State), defaultInternalCaps()) orelse return error.OutOfMemory;
        const self: *State = @ptrCast(@alignCast(raw));
        self.* = .{ .conn = conn };
        binding.espz_lwip_netconn_set_callback_arg(conn, self);
        return self;
    }

    fn destroy(self: *State) void {
        if (self.pending_recv) |buf| {
            binding.espz_lwip_netbuf_delete(buf);
        }
        heap_binding.espz_heap_caps_free(self);
    }

    fn lock(self: *State) void {
        self.mutex.lock();
    }

    fn unlock(self: *State) void {
        self.mutex.unlock();
    }

    fn wake(self: *State) void {
        self.condition.broadcast();
    }

    fn markClosed(self: *State) bool {
        self.lock();
        defer self.unlock();
        if (self.closed) return true;
        self.closed = true;
        self.read_interrupt = true;
        self.write_interrupt = true;
        self.wake();
        return false;
    }
};

pub const Tcp = struct {
    state: *State,

    const Self = @This();

    pub fn close(self: *Self) void {
        if (self.state.markClosed()) return;
        if (self.state.conn) |conn| {
            _ = binding.espz_lwip_netconn_close(conn);
        }
    }

    pub fn deinit(self: *Self) void {
        self.close();
        deleteState(self.state);
    }

    pub fn shutdown(self: *Self, how: runtime.ShutdownHow) runtime.SocketError!void {
        const conn = try liveConn(self.state);
        const shut_rx: u32 = if (how == .read or how == .both) 1 else 0;
        const shut_tx: u32 = if (how == .write or how == .both) 1 else 0;
        return switch (binding.espz_lwip_netconn_shutdown(conn, shut_rx, shut_tx)) {
            binding.err_ok => {},
            binding.err_conn, binding.err_clsd => error.NotConnected,
            binding.err_rst => error.ConnectionReset,
            else => error.Unexpected,
        };
    }

    pub fn signal(self: *Self, event: runtime.SignalEvent) void {
        signalState(self.state, event);
    }

    pub fn bind(self: *Self, addr: netip.AddrPort) runtime.SocketError!void {
        const conn = try liveConn(self.state);
        const encoded = encodeAddr(addr.addr()) catch return error.Unexpected;
        return switch (binding.espz_lwip_netconn_bind(conn, &encoded, addr.port())) {
            binding.err_ok => {},
            binding.err_use => error.AddressInUse,
            binding.err_val => error.AddressNotAvailable,
            else => error.Unexpected,
        };
    }

    pub fn listen(self: *Self, backlog: u31) runtime.SocketError!void {
        const conn = try liveConn(self.state);
        const capped_backlog: u8 = @intCast(@min(backlog, glib.std.math.maxInt(u8)));
        return switch (binding.espz_lwip_netconn_listen(conn, capped_backlog)) {
            binding.err_ok => {},
            binding.err_use => error.AddressInUse,
            binding.err_isconn => error.AlreadyConnected,
            else => error.Unexpected,
        };
    }

    pub fn accept(self: *Self, remote: ?*netip.AddrPort) runtime.SocketError!Tcp {
        const conn = try liveConn(self.state);
        var accepted: *binding.netconn = undefined;
        const rc = binding.espz_lwip_netconn_accept(conn, &accepted);
        switch (rc) {
            binding.err_ok => {},
            binding.err_wouldblock => {
                clearReadReady(self.state);
                return error.WouldBlock;
            },
            binding.err_abrt => return error.ConnectionAborted,
            binding.err_mem, binding.err_buf => return error.Unexpected,
            else => return error.Unexpected,
        }
        errdefer _ = binding.espz_lwip_netconn_delete(accepted);
        binding.espz_lwip_netconn_set_nonblocking(accepted, 1);

        if (remote) |out| {
            out.* = try getAddr(accepted, false);
        }
        const state = State.create(accepted) catch return error.Unexpected;
        return .{ .state = state };
    }

    pub fn connect(self: *Self, addr: netip.AddrPort) runtime.SocketError!void {
        const conn = try liveConn(self.state);
        const encoded = encodeAddr(addr.addr()) catch return error.Unexpected;
        return connectConn(conn, &encoded, addr.port());
    }

    pub fn finishConnect(self: *Self) runtime.SocketError!void {
        const conn = try liveConn(self.state);
        const err = binding.espz_lwip_netconn_err(conn);
        if (err == binding.err_ok) return;
        return lwipErrToSocket(err);
    }

    pub fn recv(self: *Self, buf: []u8) runtime.SocketError!usize {
        const conn = try liveConn(self.state);
        return recvTcp(self.state, conn, buf);
    }

    pub fn send(self: *Self, buf: []const u8) runtime.SocketError!usize {
        const conn = try liveConn(self.state);
        if (buf.len == 0) return 0;
        var written: usize = 0;
        return switch (binding.espz_lwip_netconn_write(conn, buf.ptr, buf.len, &written)) {
            binding.err_ok => written,
            binding.err_wouldblock, binding.err_mem => {
                setWriteReady(self.state, false);
                return error.WouldBlock;
            },
            else => |err| lwipErrToSocket(err),
        };
    }

    pub fn localAddr(self: *Self) runtime.SocketError!netip.AddrPort {
        return getAddr(try liveConn(self.state), true);
    }

    pub fn remoteAddr(self: *Self) runtime.SocketError!netip.AddrPort {
        return getAddr(try liveConn(self.state), false);
    }

    pub fn setOpt(self: *Self, opt: runtime.TcpOption) runtime.SetSockOptError!void {
        const conn = liveConn(self.state) catch return error.Closed;
        switch (opt) {
            .socket => |socket_opt| try applySocketLevelOpt(conn, socket_opt),
            .tcp => |tcp_opt| switch (tcp_opt) {
                .no_delay => |enabled| try setOptResult(binding.espz_lwip_netconn_set_tcp_no_delay(conn, if (enabled) 1 else 0)),
            },
        }
    }

    pub fn poll(self: *Self, want: runtime.PollEvents, timeout: ?glib.time.duration.Duration) runtime.PollError!runtime.PollEvents {
        return pollState(self.state, want, timeout);
    }
};

pub const Udp = struct {
    state: *State,

    const Self = @This();

    pub fn close(self: *Self) void {
        if (self.state.markClosed()) return;
        if (self.state.conn) |conn| {
            _ = binding.espz_lwip_netconn_close(conn);
        }
    }

    pub fn deinit(self: *Self) void {
        self.close();
        deleteState(self.state);
    }

    pub fn signal(self: *Self, event: runtime.SignalEvent) void {
        signalState(self.state, event);
    }

    pub fn bind(self: *Self, addr: netip.AddrPort) runtime.SocketError!void {
        const conn = try liveConn(self.state);
        const encoded = encodeAddr(addr.addr()) catch return error.Unexpected;
        return switch (binding.espz_lwip_netconn_bind(conn, &encoded, addr.port())) {
            binding.err_ok => {},
            binding.err_use => error.AddressInUse,
            binding.err_val => error.AddressNotAvailable,
            else => error.Unexpected,
        };
    }

    pub fn connect(self: *Self, addr: netip.AddrPort) runtime.SocketError!void {
        const conn = try liveConn(self.state);
        const encoded = encodeAddr(addr.addr()) catch return error.Unexpected;
        return connectConn(conn, &encoded, addr.port());
    }

    pub fn finishConnect(self: *Self) runtime.SocketError!void {
        _ = try liveConn(self.state);
        return;
    }

    pub fn recv(self: *Self, buf: []u8) runtime.SocketError!usize {
        const conn = try liveConn(self.state);
        return recvUdp(self.state, conn, buf, null);
    }

    pub fn recvFrom(self: *Self, buf: []u8, remote: ?*netip.AddrPort) runtime.SocketError!usize {
        const conn = try liveConn(self.state);
        return recvUdp(self.state, conn, buf, remote);
    }

    pub fn send(self: *Self, buf: []const u8) runtime.SocketError!usize {
        const conn = try liveConn(self.state);
        if (buf.len == 0) return 0;
        if (buf.len > max_udp_payload_len) return error.MessageTooLong;
        return switch (binding.espz_lwip_netconn_send(conn, buf.ptr, buf.len)) {
            binding.err_ok => buf.len,
            binding.err_wouldblock, binding.err_mem => {
                setWriteReady(self.state, false);
                return error.WouldBlock;
            },
            else => |err| lwipErrToSocket(err),
        };
    }

    pub fn sendTo(self: *Self, buf: []const u8, addr: netip.AddrPort) runtime.SocketError!usize {
        const conn = try liveConn(self.state);
        if (buf.len == 0) return 0;
        if (buf.len > max_udp_payload_len) return error.MessageTooLong;
        const encoded = encodeAddr(addr.addr()) catch return error.Unexpected;
        return switch (binding.espz_lwip_netconn_send_to(conn, buf.ptr, buf.len, &encoded, addr.port())) {
            binding.err_ok => buf.len,
            binding.err_wouldblock, binding.err_mem => {
                setWriteReady(self.state, false);
                return error.WouldBlock;
            },
            else => |err| lwipErrToSocket(err),
        };
    }

    pub fn localAddr(self: *Self) runtime.SocketError!netip.AddrPort {
        return getAddr(try liveConn(self.state), true);
    }

    pub fn remoteAddr(self: *Self) runtime.SocketError!netip.AddrPort {
        return getAddr(try liveConn(self.state), false);
    }

    pub fn setOpt(self: *Self, opt: runtime.UdpOption) runtime.SetSockOptError!void {
        const conn = liveConn(self.state) catch return error.Closed;
        switch (opt) {
            .socket => |socket_opt| try applySocketLevelOpt(conn, socket_opt),
        }
    }

    pub fn poll(self: *Self, want: runtime.PollEvents, timeout: ?glib.time.duration.Duration) runtime.PollError!runtime.PollEvents {
        return pollState(self.state, want, timeout);
    }
};

pub fn tcp(domain: runtime.Domain) runtime.CreateError!Tcp {
    return createRuntime(Tcp, netconnType(domain, .tcp));
}

pub fn udp(domain: runtime.Domain) runtime.CreateError!Udp {
    return createRuntime(Udp, netconnType(domain, .udp));
}

export fn espz_lwip_runtime_on_event(ctx: ?*anyopaque, event: c_int, _: u16) void {
    const state: *State = @ptrCast(@alignCast(ctx orelse return));
    state.lock();
    defer state.unlock();

    switch (event) {
        binding.netconn_event_rcvplus => state.read_ready_count +|= 1,
        binding.netconn_event_rcvminus => if (state.read_ready_count > 0) {
            state.read_ready_count -= 1;
        },
        binding.netconn_event_sendplus => state.write_ready = true,
        binding.netconn_event_sendminus => state.write_ready = false,
        binding.netconn_event_error => state.failed = true,
        else => {},
    }
    state.wake();
}

fn createRuntime(comptime Socket: type, netconn_type: u32) runtime.CreateError!Socket {
    const conn = binding.espz_lwip_netconn_new(netconn_type, null) orelse return error.SystemResources;
    errdefer _ = binding.espz_lwip_netconn_delete(conn);

    const state = State.create(conn) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .state = state };
}

fn liveConn(state: *State) runtime.SocketError!*binding.netconn {
    state.lock();
    defer state.unlock();
    if (state.closed) return error.Closed;
    return state.conn orelse error.Closed;
}

fn signalState(state: *State, event: runtime.SignalEvent) void {
    state.lock();
    defer state.unlock();
    if (state.closed) return;
    switch (event) {
        .read_interrupt => state.read_interrupt = true,
        .write_interrupt => state.write_interrupt = true,
    }
    state.wake();
}

fn pollState(state: *State, want: runtime.PollEvents, timeout: ?glib.time.duration.Duration) runtime.PollError!runtime.PollEvents {
    state.lock();
    defer state.unlock();

    const started = if (timeout != null) Time.instantNow() else 0;
    const timeout_ns = if (timeout) |duration| blk: {
        if (duration <= 0) return error.TimedOut;
        break :blk @as(u64, @intCast(duration));
    } else null;
    while (true) {
        const out = takeEventsLocked(state, want);
        if (hasAnyWantedEvent(out, want)) return out;
        if (state.closed) return error.Closed;

        if (timeout_ns) |ns| {
            const remaining_ns = remainingTimeoutNs(started, ns);
            if (remaining_ns == 0) return error.TimedOut;
            state.condition.timedWait(&state.mutex, remaining_ns) catch return error.TimedOut;
        } else {
            state.condition.wait(&state.mutex);
        }
    }
}

fn takeEventsLocked(state: *State, want: runtime.PollEvents) runtime.PollEvents {
    var out = runtime.PollEvents{};
    if (want.read and (state.read_ready_count > 0 or state.pending_recv != null)) out.read = true;
    if (want.write and state.write_ready) out.write = true;
    if (want.failed and state.failed) out.failed = true;
    if (want.hup and state.closed) out.hup = true;
    if (want.read_interrupt and state.read_interrupt) {
        state.read_interrupt = false;
        out.read_interrupt = true;
    }
    if (want.write_interrupt and state.write_interrupt) {
        state.write_interrupt = false;
        out.write_interrupt = true;
    }
    return out;
}

fn recvTcp(state: *State, conn: *binding.netconn, out: []u8) runtime.SocketError!usize {
    if (out.len == 0) return 0;
    if (try readPendingTcp(state, out)) |n| return n;

    var buf: *binding.netbuf = undefined;
    const rc = binding.espz_lwip_netconn_recv(conn, &buf);
    switch (rc) {
        binding.err_ok => {
            state.lock();
            state.pending_recv = buf;
            state.pending_recv_offset = 0;
            state.unlock();
            return (try readPendingTcp(state, out)) orelse error.Unexpected;
        },
        binding.err_clsd => return 0,
        binding.err_wouldblock => {
            clearReadReady(state);
            return error.WouldBlock;
        },
        else => return lwipErrToSocket(rc),
    }
}

fn deleteState(state: *State) void {
    if (state.conn) |conn| {
        binding.espz_lwip_netconn_set_callback_arg(conn, null);
        _ = binding.espz_lwip_netconn_delete(conn);
        state.conn = null;
    }
    state.destroy();
}

fn remainingTimeoutNs(started: u64, timeout_ns: u64) u64 {
    const now = Time.instantNow();
    const elapsed_ns = if (now > started) now - started else 0;
    if (elapsed_ns >= timeout_ns) return 0;
    return timeout_ns - elapsed_ns;
}

fn readPendingTcp(state: *State, out: []u8) runtime.SocketError!?usize {
    state.lock();
    const pending = state.pending_recv orelse {
        state.unlock();
        return null;
    };
    const offset = state.pending_recv_offset;
    state.unlock();

    const total = binding.espz_lwip_netbuf_len(pending);
    if (offset >= total) {
        binding.espz_lwip_netbuf_delete(pending);
        state.lock();
        state.pending_recv = null;
        state.pending_recv_offset = 0;
        state.unlock();
        return null;
    }

    const n = binding.espz_lwip_netbuf_copy(pending, offset, out.ptr, @min(out.len, total - offset));
    state.lock();
    state.pending_recv_offset = offset + n;
    if (state.pending_recv_offset >= total) {
        state.pending_recv = null;
        state.pending_recv_offset = 0;
        state.unlock();
        binding.espz_lwip_netbuf_delete(pending);
    } else {
        state.unlock();
    }
    return n;
}

fn recvUdp(state: *State, conn: *binding.netconn, out: []u8, remote: ?*netip.AddrPort) runtime.SocketError!usize {
    if (out.len == 0) return 0;

    var buf: *binding.netbuf = undefined;
    const rc = binding.espz_lwip_netconn_recv(conn, &buf);
    switch (rc) {
        binding.err_ok => {},
        binding.err_wouldblock => {
            clearReadReady(state);
            return error.WouldBlock;
        },
        else => return lwipErrToSocket(rc),
    }
    defer binding.espz_lwip_netbuf_delete(buf);

    const total = binding.espz_lwip_netbuf_len(buf);
    const n = binding.espz_lwip_netbuf_copy(buf, 0, out.ptr, @min(out.len, total));
    if (remote) |addr| {
        var raw_addr: binding.ip_addr = undefined;
        var port: u16 = 0;
        binding.espz_lwip_netbuf_from_addr(buf, &raw_addr, &port);
        addr.* = decodeAddr(raw_addr, port);
    }
    return n;
}

fn connectConn(conn: *binding.netconn, addr: *const binding.ip_addr, port: u16) runtime.SocketError!void {
    return switch (binding.espz_lwip_netconn_connect(conn, addr, port)) {
        binding.err_ok, binding.err_isconn => {},
        binding.err_inprogress, binding.err_wouldblock => error.WouldBlock,
        binding.err_already => error.ConnectionPending,
        else => |err| lwipErrToSocket(err),
    };
}

fn clearReadReady(state: *State) void {
    state.lock();
    state.read_ready_count = 0;
    state.unlock();
}

fn setWriteReady(state: *State, ready: bool) void {
    state.lock();
    state.write_ready = ready;
    state.unlock();
}

fn getAddr(conn: *binding.netconn, local: bool) runtime.SocketError!netip.AddrPort {
    var addr: binding.ip_addr = undefined;
    var port: u16 = 0;
    return switch (binding.espz_lwip_netconn_get_addr(conn, if (local) 1 else 0, &addr, &port)) {
        binding.err_ok => decodeAddr(addr, port),
        binding.err_conn => error.NotConnected,
        else => error.Unexpected,
    };
}

fn applySocketLevelOpt(conn: *binding.netconn, opt: runtime.SocketLevelOption) runtime.SetSockOptError!void {
    switch (opt) {
        .reuse_addr => |enabled| try setOptResult(binding.espz_lwip_netconn_set_socket_reuse_addr(conn, if (enabled) 1 else 0)),
        .reuse_port => |enabled| {
            if (enabled) return error.Unsupported;
        },
        .broadcast => |enabled| try setOptResult(binding.espz_lwip_netconn_set_socket_broadcast(conn, if (enabled) 1 else 0)),
    }
}

fn setOptResult(rc: c_int) runtime.SetSockOptError!void {
    return switch (rc) {
        binding.err_ok => {},
        binding.err_val, binding.err_arg => error.Unsupported,
        else => error.Unexpected,
    };
}

fn encodeAddr(addr: netip.Addr) error{ InvalidAddress, InvalidScopeId }!binding.ip_addr {
    if (addr.is4()) {
        var out: binding.ip_addr = .{
            .is_ipv6 = 0,
            .bytes = [_]u8{0} ** 16,
            .zone = 0,
        };
        @memcpy(out.bytes[0..4], &addr.as4().?);
        return out;
    }
    if (addr.is6()) {
        return .{
            .is_ipv6 = 1,
            .bytes = addr.as16().?,
            .zone = try parseScopeId(addr),
        };
    }
    return error.InvalidAddress;
}

fn decodeAddr(addr: binding.ip_addr, port: u16) netip.AddrPort {
    if (addr.is_ipv6 != 0) return netip.AddrPort.from16(addr.bytes, port);
    return netip.AddrPort.from4(addr.bytes[0..4].*, port);
}

fn parseScopeId(addr: netip.Addr) error{InvalidScopeId}!u32 {
    const zone = addr.zone[0..addr.zone_len];
    if (zone.len == 0) return 0;

    var scope_id: u32 = 0;
    for (zone) |c| {
        if (c < '0' or c > '9') return error.InvalidScopeId;
        const mul = @mulWithOverflow(scope_id, 10);
        if (mul[1] != 0) return error.InvalidScopeId;
        const sum = @addWithOverflow(mul[0], c - '0');
        if (sum[1] != 0) return error.InvalidScopeId;
        scope_id = sum[0];
    }
    return scope_id;
}

fn netconnType(domain: runtime.Domain, comptime kind: enum { tcp, udp }) u32 {
    return switch (kind) {
        .tcp => switch (domain) {
            .inet => binding.netconn_tcp,
            .inet6 => binding.netconn_tcp_ipv6,
        },
        .udp => switch (domain) {
            .inet => binding.netconn_udp,
            .inet6 => binding.netconn_udp_ipv6,
        },
    };
}

fn lwipErrToSocket(err: c_int) runtime.SocketError {
    return switch (err) {
        binding.err_wouldblock, binding.err_mem, binding.err_buf => error.WouldBlock,
        binding.err_use => error.AddressInUse,
        binding.err_isconn => error.AlreadyConnected,
        binding.err_already, binding.err_inprogress => error.ConnectionPending,
        binding.err_conn, binding.err_clsd => error.NotConnected,
        binding.err_abrt => error.ConnectionAborted,
        binding.err_rst => error.ConnectionReset,
        binding.err_timeout => error.TimedOut,
        binding.err_rte, binding.err_if => error.NetworkUnreachable,
        binding.err_val, binding.err_arg => error.Unexpected,
        else => error.Unexpected,
    };
}

fn hasAnyWantedEvent(got: runtime.PollEvents, want: runtime.PollEvents) bool {
    return (want.read and got.read) or
        (want.write and got.write) or
        (want.failed and got.failed) or
        (want.hup and got.hup) or
        (want.read_interrupt and got.read_interrupt) or
        (want.write_interrupt and got.write_interrupt);
}

fn defaultInternalCaps() u32 {
    return heap_binding.espz_heap_malloc_cap_internal() | heap_binding.espz_heap_malloc_cap_8bit();
}
