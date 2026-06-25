const glib = @import("glib");
const binding = @import("binding.zig");
const Time = @import("../time/instant.zig");
const esp_log = @import("../std/log.zig");
const heap_binding = @import("../std/heap/binding.zig");
const Condition = @import("../std/thread/Condition.zig");
const Mutex = @import("../std/thread/Mutex.zig");

const runtime = glib.net.runtime;
const net_interfaces = glib.net.interfaces;
const net_routes = glib.net.routes;
const net_types = glib.net.types;
const netip = glib.net.netip;
const max_udp_payload_len = glib.std.math.maxInt(u16);
const udp_recv_buffer_size = 4 * 1024 * 1024;
const udp_read_retry_poll_interval_ns: u64 = @intCast(1 * glib.time.duration.MilliSecond);
const udp_write_retry_poll_interval_ns: u64 = @intCast(1 * glib.time.duration.MilliSecond);
const SocketKind = enum {
    tcp,
    udp,
};

const State = struct {
    kind: SocketKind,
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
    event_rcvplus_total: usize = 0,
    event_rcvminus_total: usize = 0,
    event_error_total: usize = 0,
    recv_udp_ok_total: usize = 0,
    recv_udp_bytes_total: usize = 0,
    recv_udp_wouldblock_total: usize = 0,
    send_udp_ok_total: usize = 0,
    send_udp_fail_total: usize = 0,
    send_udp_local_drop_total: usize = 0,
    send_udp_retry_total: usize = 0,
    send_udp_retry_packet_total: usize = 0,
    send_udp_retry_max_per_packet: usize = 0,
    send_udp_enqueue_wait_total: usize = 0,
    send_udp_enqueue_wait_packet_total: usize = 0,
    send_udp_enqueue_wait_max_per_packet: usize = 0,
    send_udp_pps_started_ns: u64 = 0,
    send_udp_pps_last_ns: u64 = 0,
    send_udp_pps_last_total: usize = 0,

    fn create(conn: *binding.netconn, kind: SocketKind) error{OutOfMemory}!*State {
        const raw = heap_binding.espz_heap_caps_aligned_alloc(@alignOf(State), @sizeOf(State), defaultInternalCaps()) orelse return error.OutOfMemory;
        const self: *State = @ptrCast(@alignCast(raw));
        self.kind = kind;
        self.conn = conn;
        self.mutex = .{};
        self.condition = .{};
        self.closed = false;
        self.read_ready_count = 0;
        self.write_ready = true;
        self.failed = false;
        self.read_interrupt = false;
        self.write_interrupt = false;
        self.pending_recv = null;
        self.pending_recv_offset = 0;
        self.event_rcvplus_total = 0;
        self.event_rcvminus_total = 0;
        self.event_error_total = 0;
        self.recv_udp_ok_total = 0;
        self.recv_udp_bytes_total = 0;
        self.recv_udp_wouldblock_total = 0;
        self.send_udp_ok_total = 0;
        self.send_udp_fail_total = 0;
        self.send_udp_local_drop_total = 0;
        self.send_udp_retry_total = 0;
        self.send_udp_retry_packet_total = 0;
        self.send_udp_retry_max_per_packet = 0;
        self.send_udp_enqueue_wait_total = 0;
        self.send_udp_enqueue_wait_packet_total = 0;
        self.send_udp_enqueue_wait_max_per_packet = 0;
        self.send_udp_pps_started_ns = 0;
        self.send_udp_pps_last_ns = 0;
        self.send_udp_pps_last_total = 0;
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
        const state = State.create(accepted, .tcp) catch return error.Unexpected;
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
        const rc = binding.espz_lwip_netconn_write(conn, buf.ptr, buf.len, &written);
        return switch (rc) {
            binding.err_ok => written,
            binding.err_wouldblock, binding.err_mem, binding.err_inprogress, binding.err_already => {
                setWriteReady(self.state, false);
                return error.WouldBlock;
            },
            else => {
                return lwipErrToSocket(rc);
            },
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

    pub const DebugStats = struct {
        read_ready: usize,
        pending_recv: bool,
        rcvplus_total: usize,
        rcvminus_total: usize,
        event_error_total: usize,
        recv_ok_total: usize,
        recv_bytes_total: usize,
        recv_wouldblock_total: usize,
        send_ok_total: usize,
        send_fail_total: usize,
        send_local_drop_total: usize,
        send_retry_total: usize,
        send_retry_packet_total: usize,
        send_retry_max_per_packet: usize,
        send_enqueue_wait_total: usize,
        send_enqueue_wait_packet_total: usize,
        send_enqueue_wait_max_per_packet: usize,
    };

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
        const rc = binding.espz_lwip_netconn_send(conn, buf.ptr, buf.len);
        return finishUdpSend(self.state, rc, buf.len);
    }

    pub fn sendTo(self: *Self, buf: []const u8, addr: netip.AddrPort) runtime.SocketError!usize {
        const conn = try liveConn(self.state);
        if (buf.len == 0) return 0;
        if (buf.len > max_udp_payload_len) return error.MessageTooLong;
        const encoded = encodeAddr(addr.addr()) catch return error.Unexpected;
        const rc = binding.espz_lwip_netconn_send_to(conn, buf.ptr, buf.len, &encoded, addr.port());
        return finishUdpSend(self.state, rc, buf.len);
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

    pub fn debugStats(self: *Self) DebugStats {
        self.state.lock();
        const state_stats = .{
            .read_ready = self.state.read_ready_count,
            .pending_recv = self.state.pending_recv != null,
            .rcvplus_total = self.state.event_rcvplus_total,
            .rcvminus_total = self.state.event_rcvminus_total,
            .event_error_total = self.state.event_error_total,
            .recv_ok_total = self.state.recv_udp_ok_total,
            .recv_bytes_total = self.state.recv_udp_bytes_total,
            .recv_wouldblock_total = self.state.recv_udp_wouldblock_total,
            .send_ok_total = self.state.send_udp_ok_total,
            .send_fail_total = self.state.send_udp_fail_total,
            .send_local_drop_total = self.state.send_udp_local_drop_total,
            .send_retry_total = self.state.send_udp_retry_total,
            .send_retry_packet_total = self.state.send_udp_retry_packet_total,
            .send_retry_max_per_packet = self.state.send_udp_retry_max_per_packet,
            .send_enqueue_wait_total = self.state.send_udp_enqueue_wait_total,
            .send_enqueue_wait_packet_total = self.state.send_udp_enqueue_wait_packet_total,
            .send_enqueue_wait_max_per_packet = self.state.send_udp_enqueue_wait_max_per_packet,
        };
        self.state.unlock();

        return .{
            .read_ready = state_stats.read_ready,
            .pending_recv = state_stats.pending_recv,
            .rcvplus_total = state_stats.rcvplus_total,
            .rcvminus_total = state_stats.rcvminus_total,
            .event_error_total = state_stats.event_error_total,
            .recv_ok_total = state_stats.recv_ok_total,
            .recv_bytes_total = state_stats.recv_bytes_total,
            .recv_wouldblock_total = state_stats.recv_wouldblock_total,
            .send_ok_total = state_stats.send_ok_total,
            .send_fail_total = state_stats.send_fail_total,
            .send_local_drop_total = state_stats.send_local_drop_total,
            .send_retry_total = state_stats.send_retry_total,
            .send_retry_packet_total = state_stats.send_retry_packet_total,
            .send_retry_max_per_packet = state_stats.send_retry_max_per_packet,
            .send_enqueue_wait_total = state_stats.send_enqueue_wait_total,
            .send_enqueue_wait_packet_total = state_stats.send_enqueue_wait_packet_total,
            .send_enqueue_wait_max_per_packet = state_stats.send_enqueue_wait_max_per_packet,
        };
    }
};

pub fn tcp(domain: runtime.Domain) runtime.CreateError!Tcp {
    return createRuntime(Tcp, .tcp, netconnType(domain, .tcp));
}

pub fn udp(domain: runtime.Domain) runtime.CreateError!Udp {
    return createRuntime(Udp, .udp, netconnType(domain, .udp));
}

pub const interfaces = struct {
    pub fn list(out: []net_interfaces.Info) net_types.Error![]net_interfaces.Info {
        if (out.len == 0) return error.BufferTooSmall;

        var raw_buf: [16]binding.netif_info = undefined;
        const cap = @min(raw_buf.len, out.len);
        const raw_count = binding.espz_netif_list(&raw_buf, cap);
        if (raw_count > cap) return error.BufferTooSmall;

        var count: usize = 0;
        while (count < raw_count) : (count += 1) {
            out[count] = try infoFromBinding(raw_buf[count]);
        }
        return out[0..count];
    }

    pub fn addEventHook(_: net_interfaces.EventHook) net_types.Error!void {
        return error.Unsupported;
    }

    pub fn removeEventHook(_: net_interfaces.EventHook) net_types.Error!void {
        return error.Unsupported;
    }
};

pub const routes = struct {
    pub fn getDefault(family: net_types.AddressFamily) net_types.Error!?net_routes.Default {
        var id: usize = 0;
        try checkNetif(binding.espz_netif_get_default(&id));
        if (id == 0) return null;

        var raw_buf: [16]binding.netif_info = undefined;
        const raw_count = binding.espz_netif_list(&raw_buf, raw_buf.len);
        const count = @min(raw_count, raw_buf.len);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const raw = raw_buf[index];
            if (raw.id != id) continue;
            return .{
                .family = family,
                .interface_id = id,
                .gateway = if (raw.has_ipv4 != 0 and !isZero4(raw.gateway))
                    netip.Addr.from4(raw.gateway)
                else
                    null,
                .metric = if (raw.route_prio >= 0) @intCast(raw.route_prio) else 0,
            };
        }

        return .{
            .family = family,
            .interface_id = id,
        };
    }

    pub fn setDefault(route: net_routes.Default) net_types.Error!void {
        try checkNetif(binding.espz_netif_set_default(route.interface_id));
    }
};

export fn espz_lwip_runtime_on_event(ctx: ?*anyopaque, event: c_int, _: u16) void {
    const state: *State = @ptrCast(@alignCast(ctx orelse return));
    state.lock();
    defer state.unlock();

    switch (event) {
        binding.netconn_event_rcvplus => {
            state.read_ready_count +|= 1;
            state.event_rcvplus_total +|= 1;
        },
        binding.netconn_event_rcvminus => {
            state.event_rcvminus_total +|= 1;
            if (state.read_ready_count > 0) {
                state.read_ready_count -= 1;
            }
        },
        binding.netconn_event_sendplus => state.write_ready = true,
        binding.netconn_event_sendminus => state.write_ready = false,
        binding.netconn_event_error => {
            state.failed = true;
            state.event_error_total +|= 1;
        },
        else => {},
    }
    state.wake();
}

fn infoFromBinding(raw: binding.netif_info) net_types.Error!net_interfaces.Info {
    const name = raw.name[0..@min(raw.name_len, raw.name.len)];
    var info = net_interfaces.Info.init(raw.id, name);
    info.flags.up = raw.up != 0;
    info.flags.running = raw.up != 0;
    info.flags.default = raw.is_default != 0;
    if (raw.has_ipv4 != 0) {
        try info.appendAddress(.{
            .family = .ipv4,
            .address = netip.Addr.from4(raw.ipv4),
            .prefix_len = prefixLen4(raw.netmask),
        });
    }
    return info;
}

fn checkNetif(rc: c_int) net_types.Error!void {
    if (rc == 0) return;
    if (rc == -2) return error.InvalidInterface;
    if (rc == -1) return error.Unsupported;
    return error.Unexpected;
}

fn isZero4(bytes: [4]u8) bool {
    return bytes[0] == 0 and bytes[1] == 0 and bytes[2] == 0 and bytes[3] == 0;
}

fn prefixLen4(bytes: [4]u8) u8 {
    var prefix: u8 = 0;
    for (bytes) |byte| {
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            if ((byte & (@as(u8, 0x80) >> @intCast(bit))) == 0) return prefix;
            prefix += 1;
        }
    }
    return prefix;
}

fn createRuntime(comptime Socket: type, kind: SocketKind, netconn_type: u32) runtime.CreateError!Socket {
    if (binding.espz_lwip_runtime_init() != 0) return error.SystemResources;

    const conn = binding.espz_lwip_netconn_new(netconn_type, null) orelse return error.SystemResources;
    errdefer _ = binding.espz_lwip_netconn_delete(conn);
    if (kind == .udp) {
        _ = binding.espz_lwip_netconn_set_recvbuf_size(conn, udp_recv_buffer_size);
        var netif_id: usize = 0;
        var if_idx: u8 = 0;
        const rc = binding.espz_lwip_netconn_bind_default_netif(conn, &netif_id, &if_idx);
        if (rc == binding.err_ok) {
            esp_log.write(.info, .espz_udp, "bound default netif id=0x{x} if_idx={}", .{ netif_id, if_idx });
        } else {
            esp_log.write(.warn, .espz_udp, "bind default netif failed rc={} id=0x{x} if_idx={}", .{ rc, netif_id, if_idx });
        }
    }

    const state = State.create(conn, kind) catch |err| switch (err) {
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
            const wait_ns = pollWaitTimeoutNs(state, want, remaining_ns);
            state.condition.timedWait(&state.mutex, wait_ns) catch {
                if (udpReadRetryElapsed(state, want, wait_ns, remaining_ns)) return .{ .read = true };
                if (udpWriteRetryElapsed(state, want, wait_ns, remaining_ns)) {
                    state.write_ready = true;
                    continue;
                }
                return error.TimedOut;
            };
        } else {
            if (shouldRetryUdpReadPoll(state, want) or shouldRetryUdpWritePoll(state, want)) {
                const wait_ns = udpPollRetryIntervalNs(state, want);
                state.condition.timedWait(&state.mutex, wait_ns) catch {
                    if (shouldRetryUdpReadPoll(state, want)) return .{ .read = true };
                    state.write_ready = true;
                    continue;
                };
            } else {
                state.condition.wait(&state.mutex);
            }
        }
    }
}

fn pollWaitTimeoutNs(state: *const State, want: runtime.PollEvents, remaining_ns: u64) u64 {
    if (!shouldRetryUdpReadPoll(state, want) and !shouldRetryUdpWritePoll(state, want)) return remaining_ns;
    return @min(remaining_ns, udpPollRetryIntervalNs(state, want));
}

fn udpPollRetryIntervalNs(state: *const State, want: runtime.PollEvents) u64 {
    var interval: u64 = glib.std.math.maxInt(u64);
    if (shouldRetryUdpReadPoll(state, want)) interval = @min(interval, udp_read_retry_poll_interval_ns);
    if (shouldRetryUdpWritePoll(state, want)) interval = @min(interval, udp_write_retry_poll_interval_ns);
    return interval;
}

fn udpReadRetryElapsed(state: *const State, want: runtime.PollEvents, wait_ns: u64, remaining_ns: u64) bool {
    return shouldRetryUdpReadPoll(state, want) and wait_ns < remaining_ns;
}

fn udpWriteRetryElapsed(state: *const State, want: runtime.PollEvents, wait_ns: u64, remaining_ns: u64) bool {
    return shouldRetryUdpWritePoll(state, want) and wait_ns < remaining_ns;
}

fn shouldRetryUdpReadPoll(state: *const State, want: runtime.PollEvents) bool {
    return state.kind == .udp and want.read and state.read_ready_count == 0 and state.pending_recv == null;
}

fn shouldRetryUdpWritePoll(state: *const State, want: runtime.PollEvents) bool {
    return state.kind == .udp and want.write and !state.write_ready;
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
            state.lock();
            state.recv_udp_wouldblock_total +|= 1;
            state.unlock();
            clearReadReady(state);
            return error.WouldBlock;
        },
        else => return lwipErrToSocket(rc),
    }
    defer binding.espz_lwip_netbuf_delete(buf);

    const total = binding.espz_lwip_netbuf_len(buf);
    const n = binding.espz_lwip_netbuf_copy(buf, 0, out.ptr, @min(out.len, total));
    state.lock();
    state.recv_udp_ok_total +|= 1;
    state.recv_udp_bytes_total +|= n;
    state.unlock();
    if (remote) |addr| {
        var raw_addr: binding.ip_addr = undefined;
        var port: u16 = 0;
        binding.espz_lwip_netbuf_from_addr(buf, &raw_addr, &port);
        addr.* = decodeAddr(raw_addr, port);
    }
    return n;
}

fn recordUdpSendResult(state: *State, rc: c_int) void {
    const PpsLog = struct {
        total: usize,
        recent_pps: u64,
        avg_pps: u64,
        window_ms: u64,
        total_ms: u64,
    };

    var pps_log: ?PpsLog = null;

    state.lock();
    if (rc == binding.err_ok) {
        state.send_udp_ok_total +|= 1;
        const total = state.send_udp_ok_total;
        if (state.send_udp_pps_started_ns == 0) {
            const now = Time.instantNow();
            state.send_udp_pps_started_ns = now;
            state.send_udp_pps_last_ns = now;
            state.send_udp_pps_last_total = 0;
        } else if (total % 100 == 0) {
            const now = Time.instantNow();
            const window_ns = elapsedNsSince(state.send_udp_pps_last_ns, now);
            const total_ns = elapsedNsSince(state.send_udp_pps_started_ns, now);
            const window_packets = total - state.send_udp_pps_last_total;
            pps_log = .{
                .total = total,
                .recent_pps = packetsPerSecond(window_packets, window_ns),
                .avg_pps = packetsPerSecond(total, total_ns),
                .window_ms = nsToMs(window_ns),
                .total_ms = nsToMs(total_ns),
            };
            state.send_udp_pps_last_ns = now;
            state.send_udp_pps_last_total = total;
        }
    } else if (rc == binding.err_mem or rc == binding.err_buf) {
        state.send_udp_local_drop_total +|= 1;
    } else {
        state.send_udp_fail_total +|= 1;
    }
    state.unlock();

    if (pps_log) |log| {
        esp_log.write(.info, .espz_udp, "pps n={} recent={} avg={} window_ms={} total_ms={}", .{
            log.total,
            log.recent_pps,
            log.avg_pps,
            log.window_ms,
            log.total_ms,
        });
    }
}

fn finishUdpSend(state: *State, rc: c_int, len: usize) runtime.SocketError!usize {
    recordUdpSendResult(state, rc);
    return switch (rc) {
        binding.err_ok => len,
        binding.err_mem, binding.err_buf, binding.err_wouldblock => {
            setWriteReady(state, false);
            return error.WouldBlock;
        },
        else => lwipErrToSocket(rc),
    };
}

fn elapsedNsSince(started_ns: u64, now: u64) u64 {
    return if (now > started_ns) now - started_ns else 0;
}

fn packetsPerSecond(packets: usize, ns: u64) u64 {
    if (ns == 0) return 0;
    return @divTrunc(@as(u64, @intCast(packets)) * glib.time.duration.Second, ns);
}

fn nsToMs(ns: u64) u64 {
    return @divTrunc(ns, glib.time.duration.MilliSecond);
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
        .recv_buffer_size => |size| try setOptResult(binding.espz_lwip_netconn_set_recvbuf_size(conn, cappedSocketBufferSize(size))),
        .send_buffer_size => |_| return error.Unsupported,
    }
}

fn cappedSocketBufferSize(size: usize) c_int {
    return @intCast(@min(size, @as(usize, @intCast(glib.std.math.maxInt(c_int)))));
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
        const v4 = addr.as4() orelse return error.InvalidAddress;
        out.bytes[0] = v4[0];
        out.bytes[1] = v4[1];
        out.bytes[2] = v4[2];
        out.bytes[3] = v4[3];
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
