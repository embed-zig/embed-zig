const glib = @import("glib");
const kcp = @import("../kcp.zig");

const AddrPort = glib.net.netip.AddrPort;
const ikcp_max_send_segments: usize = 127;
const udp_pkg_ring_slots: usize = 64;
const udp_pkg_capacity: usize = 2048;
const read_loop_poll_ms: u32 = 100;

pub const Config = struct {
    mtu: u32 = 1400,
    send_window: u32 = 256,
    recv_window: u32 = 256,
    nodelay: i32 = 1,
    interval_ms: i32 = 10,
    resend: i32 = 2,
    no_congestion_control: i32 = 0,
    min_rto_ms: u32 = 80,
    stream: bool = true,
    ack_flush_min_count: usize = 4,
    send_batch_bytes: usize = 8192,
    max_pending_segments: ?u32 = null,
    write_timeout: ?glib.time.duration.Duration = null,
    read_timeout: ?glib.time.duration.Duration = null,
    output_write_timeout: ?glib.time.duration.Duration = null,
    tick_rx_packets: ?usize = 256,
    pump_batch_limit: ?usize = null,
    tx_buffer_capacity: usize = 32 * 1024,
    rx_buffer_capacity: usize = 64 * 1024,
};

pub const Stats = struct {
    udp_out_packets: u32 = 0,
    udp_out_bytes: u64 = 0,
    udp_out_min_bytes: u32 = 0,
    udp_out_max_bytes: u32 = 0,
    udp_out_lt_128: u32 = 0,
    udp_out_lt_512: u32 = 0,
    udp_out_lt_1024: u32 = 0,
    udp_out_ge_1024: u32 = 0,
    udp_in_packets: u32 = 0,
    udp_dropped_packets: u32 = 0,
    max_waitsnd: u32 = 0,
    write_calls: u32 = 0,
    write_wait_calls: u32 = 0,
    queue_calls: u32 = 0,
    tick_calls: u32 = 0,
    update_calls: u32 = 0,
    flush_calls: u32 = 0,
    flush_ack_calls: u32 = 0,
    pump_calls: u32 = 0,
    pump_wait_calls: u32 = 0,
    pump_timeouts: u32 = 0,
    pump_flush_calls: u32 = 0,
    pump_flush_ack_calls: u32 = 0,
    read_from_calls: u32 = 0,
    udp_ring_dropped_packets: u32 = 0,
    write_to_calls: u32 = 0,
    write_to_timeouts: u32 = 0,
    close_calls: u32 = 0,
};

pub const Snapshot = struct {
    stats: Stats,
    state: DebugState,
    tx_bytes: usize,
    rx_bytes: usize,
    pending_bytes: usize,
};

pub const DebugState = struct {
    waitsnd: u32,
    room: u32,
    cwnd: u32,
    rmt_wnd: u32,
    snd_wnd: u32,
    eff_wnd: u32,
    inflight: u32,
    snd_una: u32,
    snd_nxt: u32,
    nsnd_que: u32,
    nsnd_buf: u32,
    nrcv_que: u32,
    nrcv_buf: u32,
    rcv_wnd: u32,
    rx_rto: u32,
    ssthresh: u32,
    xmit: u32,
};

pub fn make(comptime grt: type) type {
    return struct {
        const Self = @This();
        const std = grt.std;
        const AtomicBool = std.atomic.Value(bool);
        const Mutex = grt.sync.Mutex;
        const Condition = grt.sync.Condition;
        const SegmentPool = kcp.SegmentPool.make(grt);

        allocator: grt.std.mem.Allocator,
        pc: grt.net.PacketConn,
        remote: AddrPort,
        inst: *kcp.Kcp,
        segment_pool: SegmentPool,
        owns_segment_pool: bool = false,
        output_ctx: OutputContext,
        output_err: ?anyerror = null,
        config: Config,
        stats: Stats = .{},
        start_at: glib.time.instant.Time,
        udp_pkg_buf: []u8,
        udp_pkg_lens: []usize,
        tx_buf: []u8,
        rx_buf: []u8,
        udp_pkg_head: usize = 0,
        udp_pkg_len: usize = 0,
        udp_pkg_reserved: bool = false,
        tx_head: usize = 0,
        tx_len: usize = 0,
        rx_head: usize = 0,
        rx_len: usize = 0,
        mu: Mutex = .{},
        cond: Condition = .{},
        driver_err: ?anyerror = null,
        last_debug_state: DebugState = emptyDebugState(),
        last_write_wait_log_ms: u32 = 0,
        last_drive_log_ms: u32 = 0,
        pending_ack_since_ms: ?u32 = null,
        closed: bool = false,

        pub fn init(
            self: *Self,
            allocator: grt.std.mem.Allocator,
            pc: grt.net.PacketConn,
            remote: AddrPort,
            conv: u32,
            config: Config,
        ) !void {
            self.initBase(allocator, pc, remote, config);
            const mss = @as(usize, @intCast(config.mtu)) -| kcp.OVERHEAD;
            const reserve_segments = @as(usize, @intCast(config.recv_window));
            self.segment_pool = try SegmentPool.init(allocator, mss, reserve_segments);
            self.owns_segment_pool = true;
            errdefer self.segment_pool.deinit();
            try self.initKcp(conv, &self.segment_pool);
        }

        pub fn initWithSegmentPool(
            self: *Self,
            allocator: grt.std.mem.Allocator,
            pc: grt.net.PacketConn,
            remote: AddrPort,
            conv: u32,
            config: Config,
            segment_pool: *SegmentPool,
        ) !void {
            self.initBase(allocator, pc, remote, config);
            try self.initKcp(conv, segment_pool);
        }

        fn initBase(
            self: *Self,
            allocator: grt.std.mem.Allocator,
            pc: grt.net.PacketConn,
            remote: AddrPort,
            config: Config,
        ) void {
            const start_at = grt.time.instant.now();
            self.* = .{
                .allocator = allocator,
                .pc = pc,
                .remote = remote,
                .inst = undefined,
                .segment_pool = undefined,
                .owns_segment_pool = false,
                .output_ctx = undefined,
                .config = config,
                .start_at = start_at,
                .udp_pkg_buf = undefined,
                .udp_pkg_lens = undefined,
                .tx_buf = undefined,
                .rx_buf = undefined,
            };
        }

        fn initKcp(self: *Self, conv: u32, segment_pool: *SegmentPool) !void {
            const allocator = self.allocator;
            const config = self.config;

            self.udp_pkg_buf = try allocator.alloc(u8, udp_pkg_ring_slots * udp_pkg_capacity);
            errdefer allocator.free(self.udp_pkg_buf);
            self.udp_pkg_lens = try allocator.alloc(usize, udp_pkg_ring_slots);
            errdefer allocator.free(self.udp_pkg_lens);
            self.tx_buf = try allocator.alloc(u8, config.tx_buffer_capacity);
            errdefer allocator.free(self.tx_buf);
            self.rx_buf = try allocator.alloc(u8, config.rx_buffer_capacity);
            errdefer allocator.free(self.rx_buf);
            self.output_ctx = .{ .session = self };
            const kcp_allocator = segment_pool.allocator();
            self.inst = kcp.createWithAllocator(conv, &self.output_ctx, kcp_allocator) orelse return error.KcpSessionCreateFailed;
            errdefer kcp.release(self.inst);

            kcp.setOutput(self.inst, OutputContext.output);
            if (kcp.setMtu(self.inst, @intCast(config.mtu)) != 0) return error.KcpSessionSetMtuFailed;
            if (kcp.nodelay(
                self.inst,
                config.nodelay,
                config.interval_ms,
                config.resend,
                config.no_congestion_control,
            ) != 0) return error.KcpSessionNodelayFailed;
            if (kcp.wndsize(self.inst, @intCast(config.send_window), @intCast(config.recv_window)) != 0) {
                return error.KcpSessionWndsizeFailed;
            }
            if (config.min_rto_ms > 0) {
                self.inst.*.rx_minrto = @intCast(config.min_rto_ms);
                if (self.inst.*.rx_rto < self.inst.*.rx_minrto) self.inst.*.rx_rto = self.inst.*.rx_minrto;
            }
            self.inst.*.stream = if (config.stream) 1 else 0;
            try self.updateInner();
        }

        pub fn deinit(self: *Self) void {
            kcp.release(self.inst);
            if (self.owns_segment_pool) self.segment_pool.deinit();
            self.allocator.free(self.rx_buf);
            self.allocator.free(self.tx_buf);
            self.allocator.free(self.udp_pkg_lens);
            self.allocator.free(self.udp_pkg_buf);
            self.* = undefined;
        }

        pub fn write(self: *Self, buf: []const u8) !usize {
            if (buf.len == 0) return 0;

            const started = grt.time.instant.now();
            var offset: usize = 0;
            self.mu.lock();
            defer self.mu.unlock();
            if (self.closed) return error.KcpSessionClosed;
            if (self.driver_err) |err| return err;
            self.stats.write_calls +%= 1;
            while (offset < buf.len) {
                if (self.closed) return error.KcpSessionClosed;
                if (self.driver_err) |err| return err;
                const queued = self.writeTxLocked(buf[offset..]);
                if (queued > 0) {
                    offset += queued;
                    self.cond.broadcast();
                    continue;
                }

                if (self.writeTimedOut(started)) {
                    if (offset > 0) return offset;
                    const state = self.last_debug_state;
                    std.log.scoped(.kcp_session).err(
                        "write timeout offset={d}/{d} tx={d} rx={d} ws={d} room={d} out={d} in={d} tick={d} queue={d} update={d} read_from={d} driver_err={s}",
                        .{
                            offset,
                            buf.len,
                            self.tx_len,
                            self.rx_len,
                            state.waitsnd,
                            state.room,
                            self.stats.udp_out_packets,
                            self.stats.udp_in_packets,
                            self.stats.tick_calls,
                            self.stats.queue_calls,
                            self.stats.update_calls,
                            self.stats.read_from_calls,
                            if (self.driver_err) |err| @errorName(err) else "null",
                        },
                    );
                    return error.KcpSessionWriteTimeout;
                }

                self.stats.write_wait_calls +%= 1;
                self.logWriteWaitLocked(offset, buf.len);
                self.waitLocked(started, self.config.write_timeout);
            }
            return offset;
        }

        pub fn read(self: *Self, buf: []u8) !usize {
            if (buf.len == 0) return 0;
            self.mu.lock();
            defer self.mu.unlock();
            if (self.closed and self.rx_len == 0) return error.KcpSessionClosed;
            if (self.driver_err) |err| return err;
            const n = self.readRxLocked(buf);
            if (n > 0) self.cond.broadcast();
            return n;
        }

        pub fn tick(self: *Self) !u32 {
            self.mu.lock();
            defer self.mu.unlock();
            self.cond.broadcast();
            if (self.closed) return 0;
            if (self.driver_err) |err| return err;
            return @intCast(@max(self.config.interval_ms, 1));
        }

        pub fn driveLoop(self: *Self, stop: *AtomicBool) !void {
            while (!stop.load(.acquire)) {
                if (self.isClosed()) return;
                self.driveOnce() catch |err| {
                    self.setDriverErr(err);
                    return err;
                };
            }
        }

        pub fn readLoop(self: *Self, stop: *AtomicBool) !void {
            while (!stop.load(.acquire)) {
                if (self.isClosed()) return;
                self.readOnce() catch |err| {
                    self.setDriverErr(err);
                    return err;
                };
            }
        }

        pub fn close(self: *Self) void {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.closed) return;
            self.closed = true;
            self.stats.close_calls +%= 1;
            self.cond.broadcast();
            self.pc.close();
        }

        pub fn resetStats(self: *Self) void {
            self.mu.lock();
            defer self.mu.unlock();
            self.stats = .{};
        }

        pub fn debugState(self: *Self) DebugState {
            self.mu.lock();
            defer self.mu.unlock();
            return self.last_debug_state;
        }

        pub fn pendingBytes(self: *Self) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.tx_len + self.rx_len + self.last_debug_state.waitsnd;
        }

        pub fn snapshot(self: *Self) Snapshot {
            self.mu.lock();
            defer self.mu.unlock();
            return .{
                .stats = self.stats,
                .state = self.last_debug_state,
                .tx_bytes = self.tx_len,
                .rx_bytes = self.rx_len,
                .pending_bytes = self.tx_len + self.rx_len + self.last_debug_state.waitsnd,
            };
        }

        fn driveOnce(self: *Self) !void {
            self.stats.tick_calls +%= 1;
            var progressed = false;
            const tick_started = grt.time.instant.now();
            if (try self.drainUdpRingToKcp(self.tickRxLimit()) > 0) progressed = true;
            if (try self.drainKcpRecvToRxRing() > 0) progressed = true;
            if (try self.drainTxRingToKcp()) progressed = true;
            try self.updateInner();
            if (try self.drainKcpRecvToRxRing() > 0) progressed = true;
            const wait_ms = self.nextWaitMs();
            self.logDriveState(progressed, wait_ms);
            if (!progressed and !self.hasImmediateWork()) {
                const wait_duration = self.remainingInterval(tick_started, wait_ms);
                self.waitForDriveWork(wait_duration);
            }
        }

        fn drainTxRingToKcp(self: *Self) !bool {
            var progressed = false;
            while (self.canQueue()) {
                self.mu.lock();
                if (self.tx_len == 0) {
                    self.mu.unlock();
                    break;
                }
                const span = self.txContiguousReadSpanLocked(self.kcpSendBatchLimit());
                const rc = kcp.send(self.inst, @ptrCast(span.ptr), @intCast(span.len));
                if (rc < 0) {
                    self.mu.unlock();
                    return error.KcpSessionSendFailed;
                }
                ringDiscard(self.tx_buf, &self.tx_head, &self.tx_len, span.len);
                self.cond.broadcast();
                self.mu.unlock();
                self.stats.queue_calls +%= 1;
                self.recordPending();
                progressed = true;
            }
            return progressed;
        }

        fn drainKcpRecvToRxRing(self: *Self) !usize {
            var count: usize = 0;
            while (true) {
                self.mu.lock();
                const span = self.rxContiguousWriteSpanLocked();
                if (span.len == 0) {
                    self.mu.unlock();
                    break;
                }
                const n = kcp.recv(self.inst, @ptrCast(span.ptr), @intCast(span.len));
                if (n <= 0) {
                    self.mu.unlock();
                    break;
                }
                self.rx_len += @intCast(n);
                self.cond.broadcast();
                self.mu.unlock();
                count += 1;
            }
            return count;
        }

        fn readOnce(self: *Self) !void {
            const reservation = self.reserveUdpPacketSlot();
            if (reservation == null) {
                self.waitForUdpSlot();
                return;
            }
            const reserved = reservation.?;
            self.pc.setReadDeadline(glib.time.instant.add(grt.time.instant.now(), readLoopDuration()));
            const result = self.pc.readFrom(reserved.buf) catch |err| {
                self.releaseUdpPacketReservation();
                switch (err) {
                    error.TimedOut => return,
                    error.Closed => {
                        self.closeFromReadLoop();
                        return;
                    },
                    else => return err,
                }
            };
            self.commitUdpPacketSlot(reserved.index, result.bytes_read);
        }

        fn drainUdpRingToKcp(self: *Self, max_packets: ?usize) !usize {
            var input_count: usize = 0;
            var flush_pending_ack = false;
            self.stats.pump_calls +%= 1;

            while (true) {
                self.mu.lock();
                if (self.udp_pkg_len == 0) {
                    self.mu.unlock();
                    break;
                }
                const index = self.udp_pkg_head;
                const frame = self.udpPacketSlot(index)[0..self.udp_pkg_lens[index]];
                if (frame.len >= kcp.OVERHEAD and readLe32(frame) == self.inst.*.conv) {
                    self.inst.*.current = self.nowMs();
                    const rc = kcp.input(self.inst, @ptrCast(frame.ptr), @intCast(frame.len));
                    if (rc < 0) {
                        self.mu.unlock();
                        return error.KcpSessionInputFailed;
                    }
                    if (self.ackCountInner() > 0 and self.pending_ack_since_ms == null) {
                        self.pending_ack_since_ms = self.nowMs();
                    }
                    if (self.ackCountInner() > 0) flush_pending_ack = true;
                    self.stats.udp_in_packets +%= 1;
                }
                self.udp_pkg_head = (self.udp_pkg_head + 1) % udp_pkg_ring_slots;
                self.udp_pkg_len -= 1;
                self.cond.broadcast();
                self.mu.unlock();

                try self.checkOutput();
                input_count += 1;
                if (max_packets) |limit| {
                    if (input_count >= limit) break;
                }
            }

            if (flush_pending_ack and self.shouldFlushAckNow()) {
                self.stats.pump_flush_ack_calls +%= 1;
                try self.flushAckInner();
            }

            self.recordPending();
            return input_count;
        }

        fn writeTxLocked(self: *Self, buf: []const u8) usize {
            if (self.tx_len == 0) self.tx_head = 0;
            const n = @min(buf.len, self.txSpaceLocked());
            if (n == 0) return 0;
            ringWrite(self.tx_buf, &self.tx_head, &self.tx_len, buf[0..n]);
            return n;
        }

        fn readRxLocked(self: *Self, out: []u8) usize {
            const n = @min(out.len, self.rx_len);
            if (n == 0) return 0;
            ringRead(self.rx_buf, &self.rx_head, &self.rx_len, out[0..n]);
            return n;
        }

        fn txSpaceLocked(self: *const Self) usize {
            return self.tx_buf.len - self.tx_len;
        }

        fn rxSpaceLocked(self: *const Self) usize {
            return self.rx_buf.len - self.rx_len;
        }

        const UdpPacketReservation = struct {
            index: usize,
            buf: []u8,
        };

        fn reserveUdpPacketSlot(self: *Self) ?UdpPacketReservation {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.closed) return null;
            if (self.udp_pkg_reserved) return null;
            if (self.udp_pkg_len >= udp_pkg_ring_slots) return null;
            const index = (self.udp_pkg_head + self.udp_pkg_len) % udp_pkg_ring_slots;
            self.udp_pkg_reserved = true;
            return .{
                .index = index,
                .buf = self.udpPacketSlot(index),
            };
        }

        fn releaseUdpPacketReservation(self: *Self) void {
            self.mu.lock();
            defer self.mu.unlock();
            self.udp_pkg_reserved = false;
            self.cond.broadcast();
        }

        fn commitUdpPacketSlot(self: *Self, index: usize, len: usize) void {
            self.mu.lock();
            defer self.mu.unlock();
            self.udp_pkg_reserved = false;
            self.stats.read_from_calls +%= 1;
            const expected = (self.udp_pkg_head + self.udp_pkg_len) % udp_pkg_ring_slots;
            if (self.closed or index != expected or self.udp_pkg_len >= udp_pkg_ring_slots) {
                self.stats.udp_ring_dropped_packets +%= 1;
                self.cond.broadcast();
                return;
            }
            self.udp_pkg_lens[index] = @min(len, udp_pkg_capacity);
            self.udp_pkg_len += 1;
            self.cond.broadcast();
        }

        fn udpPacketSlot(self: *Self, index: usize) []u8 {
            const start = index * udp_pkg_capacity;
            return self.udp_pkg_buf[start..][0..udp_pkg_capacity];
        }

        fn txContiguousReadSpanLocked(self: *Self, limit: usize) []const u8 {
            const n = @min(@min(self.tx_len, limit), self.tx_buf.len - self.tx_head);
            return self.tx_buf[self.tx_head..][0..n];
        }

        fn rxContiguousWriteSpanLocked(self: *Self) []u8 {
            if (self.rx_len == 0) self.rx_head = 0;
            const space = self.rxSpaceLocked();
            if (space == 0) return self.rx_buf[0..0];
            const tail = (self.rx_head + self.rx_len) % self.rx_buf.len;
            const n = @min(space, self.rx_buf.len - tail);
            return self.rx_buf[tail..][0..n];
        }

        fn hasImmediateWork(self: *Self) bool {
            self.mu.lock();
            defer self.mu.unlock();
            return self.udp_pkg_len > 0 or
                self.tx_len > 0 or
                (self.rxSpaceLocked() > 0 and self.inst.*.nrcv_que > 0);
        }

        fn waitForDriveWork(self: *Self, duration: glib.time.duration.Duration) void {
            if (duration == 0) return;
            self.mu.lock();
            defer self.mu.unlock();
            if (self.closed or self.driver_err != null) return;
            self.cond.timedWait(&self.mu, @intCast(duration)) catch {};
        }

        fn waitForUdpSlot(self: *Self) void {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.closed or self.driver_err != null) return;
            self.cond.timedWait(&self.mu, @intCast(readLoopDuration())) catch {};
        }

        fn closeFromReadLoop(self: *Self) void {
            self.mu.lock();
            defer self.mu.unlock();
            self.closed = true;
            self.cond.broadcast();
        }

        fn updateInner(self: *Self) !void {
            self.stats.update_calls +%= 1;
            self.inst.*.current = self.nowMs();
            kcp.update(self.inst, self.inst.*.current);
            try self.checkOutput();
            self.clearPendingAckIfFlushed();
            self.recordPending();
        }

        fn flushAckInner(self: *Self) !void {
            if (self.ackCountInner() == 0) return;
            self.stats.flush_ack_calls +%= 1;
            try self.flushInner();
            self.pending_ack_since_ms = null;
        }

        fn flushInner(self: *Self) !void {
            self.stats.flush_calls +%= 1;
            self.inst.*.current = self.nowMs();
            kcp.flush(self.inst);
            try self.checkOutput();
            self.clearPendingAckIfFlushed();
            self.recordPending();
        }

        fn checkOutput(self: *Self) !void {
            if (self.output_err) |err| {
                self.output_err = null;
                return err;
            }
        }

        fn recordPending(self: *Self) void {
            const state = self.debugStateInner();
            const pending = state.waitsnd;
            if (pending > self.stats.max_waitsnd) self.stats.max_waitsnd = pending;
            self.mu.lock();
            defer self.mu.unlock();
            self.last_debug_state = state;
        }

        fn debugStateInner(self: *const Self) DebugState {
            var eff_wnd = @min(self.inst.*.snd_wnd, self.inst.*.rmt_wnd);
            if (self.inst.*.nocwnd == 0) eff_wnd = @min(eff_wnd, self.inst.*.cwnd);
            return .{
                .waitsnd = self.waitsndInner(),
                .room = self.sendRoomInner(),
                .cwnd = self.inst.*.cwnd,
                .rmt_wnd = self.inst.*.rmt_wnd,
                .snd_wnd = self.inst.*.snd_wnd,
                .eff_wnd = eff_wnd,
                .inflight = self.inst.*.snd_nxt -% self.inst.*.snd_una,
                .snd_una = self.inst.*.snd_una,
                .snd_nxt = self.inst.*.snd_nxt,
                .nsnd_que = self.inst.*.nsnd_que,
                .nsnd_buf = self.inst.*.nsnd_buf,
                .nrcv_que = self.inst.*.nrcv_que,
                .nrcv_buf = self.inst.*.nrcv_buf,
                .rcv_wnd = self.inst.*.rcv_wnd,
                .rx_rto = @intCast(self.inst.*.rx_rto),
                .ssthresh = self.inst.*.ssthresh,
                .xmit = self.inst.*.xmit,
            };
        }

        fn isClosed(self: *Self) bool {
            self.mu.lock();
            defer self.mu.unlock();
            return self.closed;
        }

        fn setDriverErr(self: *Self, err: anyerror) void {
            self.mu.lock();
            defer self.mu.unlock();
            self.driver_err = err;
            self.cond.broadcast();
        }

        fn waitLocked(self: *Self, started: glib.time.instant.Time, timeout: ?glib.time.duration.Duration) void {
            if (timeout) |duration| {
                const elapsed = glib.time.instant.sub(grt.time.instant.now(), started);
                if (elapsed >= duration) return;
                const remaining: u64 = @intCast(duration - elapsed);
                self.cond.timedWait(&self.mu, @min(remaining, 10 * glib.time.duration.MilliSecond)) catch {};
            } else {
                self.cond.wait(&self.mu);
            }
        }

        fn nowMs(self: *const Self) u32 {
            const elapsed = glib.time.instant.sub(grt.time.instant.now(), self.start_at);
            if (elapsed <= 0) return 0;
            return @truncate(@as(u64, @intCast(@divTrunc(elapsed, glib.time.duration.MilliSecond))));
        }

        fn canQueue(self: *const Self) bool {
            return self.waitsndInner() < self.pendingLimit();
        }

        fn pendingLimit(self: *const Self) u32 {
            const configured = self.config.max_pending_segments orelse self.inst.*.snd_wnd;
            return @max(@min(configured, self.inst.*.snd_wnd), 1);
        }

        fn waitsndInner(self: *const Self) u32 {
            const pending = kcp.waitsnd(self.inst);
            if (pending <= 0) return 0;
            return @intCast(pending);
        }

        fn sendRoomInner(self: *const Self) u32 {
            const pending = self.waitsndInner();
            const limit = self.pendingLimit();
            if (pending >= limit) return 0;
            return limit - pending;
        }

        fn kcpSendBatchLimit(self: *const Self) usize {
            const mss = @max(@as(usize, @intCast(self.inst.*.mss)), 1);
            const configured = @max(self.config.send_batch_bytes, mss);
            const ikcp_limit = ikcp_max_send_segments * mss;
            const room_limit = @max(@as(usize, @intCast(self.sendRoomInner())), 1) * mss;
            return @max(@min(@min(configured, ikcp_limit), room_limit), 1);
        }

        fn ackCountInner(self: *const Self) usize {
            return @intCast(self.inst.*.ackcount);
        }

        fn shouldFlushAckNow(self: *Self) bool {
            const ack_count = self.ackCountInner();
            if (ack_count == 0) {
                self.pending_ack_since_ms = null;
                return false;
            }
            if (ack_count >= self.config.ack_flush_min_count) return true;
            const max_delay_ms: u32 = @intCast(@max(self.config.interval_ms, 1));
            if (max_delay_ms == 0) return true;
            const now_ms = self.nowMs();
            const pending_since = self.pending_ack_since_ms orelse {
                self.pending_ack_since_ms = now_ms;
                return false;
            };
            return now_ms -% pending_since >= max_delay_ms;
        }

        fn clearPendingAckIfFlushed(self: *Self) void {
            if (self.ackCountInner() == 0) self.pending_ack_since_ms = null;
        }

        fn tickRxLimit(self: *const Self) ?usize {
            return self.config.tick_rx_packets orelse self.config.pump_batch_limit;
        }

        fn nextWaitMs(self: *const Self) u32 {
            const now_ms = self.nowMs();
            const next_ms: u32 = @intCast(kcp.check(self.inst, now_ms));
            if (next_ms <= now_ms) return 0;
            const interval_ms: u32 = @intCast(@max(self.config.interval_ms, 1));
            return @min(next_ms - now_ms, interval_ms);
        }

        fn intervalDuration(self: *const Self) glib.time.duration.Duration {
            const interval_ms: u32 = @intCast(@max(self.config.interval_ms, 1));
            return @as(glib.time.duration.Duration, interval_ms) * glib.time.duration.MilliSecond;
        }

        fn remainingInterval(self: *const Self, tick_started: glib.time.instant.Time, wait_ms: u32) glib.time.duration.Duration {
            const budget = @min(self.intervalDuration(), @as(glib.time.duration.Duration, wait_ms) * glib.time.duration.MilliSecond);
            if (budget <= 0) return 0;
            const elapsed = glib.time.instant.sub(grt.time.instant.now(), tick_started);
            if (elapsed >= budget) return 0;
            return budget - elapsed;
        }

        fn writeTimedOut(self: *const Self, started: glib.time.instant.Time) bool {
            const timeout = self.config.write_timeout orelse return false;
            return glib.time.instant.sub(grt.time.instant.now(), started) >= timeout;
        }

        const OutputContext = struct {
            session: *Self,

            fn output(buf: [*c]const u8, len: c_int, _: ?*kcp.Kcp, user: ?*anyopaque) callconv(.c) c_int {
                const self: *@This() = @ptrCast(@alignCast(user orelse return -1));
                return self.session.writePacket(buf, len);
            }
        };

        fn writePacket(self: *Self, buf: [*c]const u8, len: c_int) c_int {
            if (len < 0) {
                self.output_err = error.KcpSessionNegativePacketLength;
                return -1;
            }
            const frame = buf[0..@intCast(len)];
            const write_start = if (self.config.output_write_timeout != null) grt.time.instant.now() else 0;
            self.stats.write_to_calls +%= 1;
            if (self.config.output_write_timeout) |timeout| {
                self.pc.setWriteDeadline(glib.time.instant.add(write_start, timeout));
            }
            defer if (self.config.output_write_timeout != null) self.pc.setWriteDeadline(null);

            const written = self.pc.writeTo(frame, self.remote) catch |err| switch (err) {
                error.TimedOut => {
                    self.stats.write_to_timeouts +%= 1;
                    self.stats.udp_dropped_packets +%= 1;
                    std.log.scoped(.kcp_session).warn(
                        "udp timeout len={d} out={d} in={d} drop={d}",
                        .{ frame.len, self.stats.udp_out_packets, self.stats.udp_in_packets, self.stats.udp_dropped_packets },
                    );
                    return @intCast(frame.len);
                },
                else => {
                    std.log.scoped(.kcp_session).warn(
                        "udp err={s} len={d} out={d} in={d}",
                        .{ @errorName(err), frame.len, self.stats.udp_out_packets, self.stats.udp_in_packets },
                    );
                    self.output_err = err;
                    return -1;
                },
            };
            if (written != frame.len) {
                std.log.scoped(.kcp_session).warn(
                    "udp short wr={d} len={d} out={d} in={d}",
                    .{ written, frame.len, self.stats.udp_out_packets, self.stats.udp_in_packets },
                );
                self.output_err = error.ShortKcpSessionUdpWrite;
                return -1;
            }
            self.recordUdpOut(frame.len);
            return @intCast(written);
        }

        fn recordUdpOut(self: *Self, frame_len: usize) void {
            const len: u32 = @intCast(frame_len);
            const first = self.stats.udp_out_packets == 0;
            self.stats.udp_out_packets +%= 1;
            self.stats.udp_out_bytes +%= @intCast(frame_len);
            if (first or len < self.stats.udp_out_min_bytes) self.stats.udp_out_min_bytes = len;
            if (len > self.stats.udp_out_max_bytes) self.stats.udp_out_max_bytes = len;
            if (len < 128) {
                self.stats.udp_out_lt_128 +%= 1;
            } else if (len < 512) {
                self.stats.udp_out_lt_512 +%= 1;
            } else if (len < 1024) {
                self.stats.udp_out_lt_1024 +%= 1;
            } else {
                self.stats.udp_out_ge_1024 +%= 1;
            }
        }

        fn logWriteWaitLocked(self: *Self, offset: usize, total: usize) void {
            const now_ms = self.nowMs();
            if (now_ms -% self.last_write_wait_log_ms < 1000) return;
            self.last_write_wait_log_ms = now_ms;
            const state = self.last_debug_state;
            std.log.scoped(.kcp_session).info(
                "ww {d}/{d} tx={d} rx={d} ws={d} room={d} cw={d} rw={d} eff={d} infl={d} una={d} nxt={d} sq={d} sb={d} rq={d} rb={d} rto={d} ss={d} xmit={d} out={d} in={d}",
                .{
                    offset,
                    total,
                    self.tx_len,
                    self.rx_len,
                    state.waitsnd,
                    state.room,
                    state.cwnd,
                    state.rmt_wnd,
                    state.eff_wnd,
                    state.inflight,
                    state.snd_una,
                    state.snd_nxt,
                    state.nsnd_que,
                    state.nsnd_buf,
                    state.nrcv_que,
                    state.nrcv_buf,
                    state.rx_rto,
                    state.ssthresh,
                    state.xmit,
                    self.stats.udp_out_packets,
                    self.stats.udp_in_packets,
                },
            );
        }

        fn logDriveState(self: *Self, progressed: bool, wait_ms: u32) void {
            const now_ms = self.nowMs();
            if (now_ms -% self.last_drive_log_ms < 1000) return;
            self.last_drive_log_ms = now_ms;
            const snap = self.snapshot();
            const avg_out = if (snap.stats.udp_out_packets == 0)
                @as(u64, 0)
            else
                @divTrunc(snap.stats.udp_out_bytes, @as(u64, snap.stats.udp_out_packets));
            std.log.scoped(.kcp_session).info(
                "ds p={d} w={d} tx={d} rx={d} ws={d} room={d} cw={d} rw={d} eff={d} infl={d} una={d} nxt={d} sq={d} sb={d} rq={d} rb={d} rto={d} ss={d} xmit={d} out={d} outB={d} avg={d} min={d} max={d} lt128={d} lt512={d} lt1024={d} ge1024={d} in={d} drop={d}",
                .{
                    if (progressed) @as(u32, 1) else 0,
                    wait_ms,
                    snap.tx_bytes,
                    snap.rx_bytes,
                    snap.state.waitsnd,
                    snap.state.room,
                    snap.state.cwnd,
                    snap.state.rmt_wnd,
                    snap.state.eff_wnd,
                    snap.state.inflight,
                    snap.state.snd_una,
                    snap.state.snd_nxt,
                    snap.state.nsnd_que,
                    snap.state.nsnd_buf,
                    snap.state.nrcv_que,
                    snap.state.nrcv_buf,
                    snap.state.rx_rto,
                    snap.state.ssthresh,
                    snap.state.xmit,
                    snap.stats.udp_out_packets,
                    snap.stats.udp_out_bytes,
                    avg_out,
                    snap.stats.udp_out_min_bytes,
                    snap.stats.udp_out_max_bytes,
                    snap.stats.udp_out_lt_128,
                    snap.stats.udp_out_lt_512,
                    snap.stats.udp_out_lt_1024,
                    snap.stats.udp_out_ge_1024,
                    snap.stats.udp_in_packets,
                    snap.stats.udp_dropped_packets,
                },
            );
        }
    };
}

fn readLe32(buf: []const u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

fn readLoopDuration() glib.time.duration.Duration {
    return @as(glib.time.duration.Duration, read_loop_poll_ms) * glib.time.duration.MilliSecond;
}

fn ringWrite(ring: []u8, head: *usize, len: *usize, src: []const u8) void {
    if (src.len == 0) return;
    const tail = (head.* + len.*) % ring.len;
    const first = @min(src.len, ring.len - tail);
    @memcpy(ring[tail..][0..first], src[0..first]);
    if (first < src.len) {
        @memcpy(ring[0 .. src.len - first], src[first..]);
    }
    len.* += src.len;
}

fn ringRead(ring: []u8, head: *usize, len: *usize, out: []u8) void {
    if (out.len == 0) return;
    const first = @min(out.len, ring.len - head.*);
    @memcpy(out[0..first], ring[head.*..][0..first]);
    if (first < out.len) {
        @memcpy(out[first..], ring[0 .. out.len - first]);
    }
    head.* = (head.* + out.len) % ring.len;
    len.* -= out.len;
}

fn ringDiscard(ring: []const u8, head: *usize, len: *usize, n: usize) void {
    if (n == 0) return;
    head.* = (head.* + n) % ring.len;
    len.* -= n;
}

fn emptyDebugState() DebugState {
    return .{
        .waitsnd = 0,
        .room = 0,
        .cwnd = 0,
        .rmt_wnd = 0,
        .snd_wnd = 0,
        .eff_wnd = 0,
        .inflight = 0,
        .snd_una = 0,
        .snd_nxt = 0,
        .nsnd_que = 0,
        .nsnd_buf = 0,
        .nrcv_que = 0,
        .nrcv_buf = 0,
        .rcv_wnd = 0,
        .rx_rto = 0,
        .ssthresh = 0,
        .xmit = 0,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    return glib.testing.TestRunner.fromFn(grt.std, 128 * 1024, struct {
        fn run(_: *glib.testing.T, allocator: grt.std.mem.Allocator) !void {
            _ = allocator;
            const std = grt.std;
            const Session = make(grt);

            var tx_storage: [8]u8 = undefined;
            var rx_storage: [8]u8 = undefined;
            var session: Session = .{
                .allocator = undefined,
                .pc = undefined,
                .remote = undefined,
                .inst = undefined,
                .segment_pool = undefined,
                .output_ctx = undefined,
                .config = .{},
                .start_at = grt.time.instant.now(),
                .udp_pkg_buf = &.{},
                .udp_pkg_lens = &.{},
                .tx_buf = &tx_storage,
                .rx_buf = &rx_storage,
            };

            session.tx_head = 6;
            session.tx_len = 0;
            try std.testing.expectEqual(@as(usize, 4), session.writeTxLocked("abcd"));
            try std.testing.expectEqual(@as(usize, 0), session.tx_head);
            try std.testing.expectEqual(@as(usize, 4), session.tx_len);
            try std.testing.expectEqualSlices(u8, "abcd", tx_storage[0..4]);

            session.rx_head = 6;
            session.rx_len = 0;
            const span = session.rxContiguousWriteSpanLocked();
            try std.testing.expectEqual(@as(usize, 0), session.rx_head);
            try std.testing.expectEqual(@as(usize, rx_storage.len), span.len);
            try std.testing.expectEqual(@intFromPtr(&rx_storage[0]), @intFromPtr(span.ptr));
        }
    }.run);
}
