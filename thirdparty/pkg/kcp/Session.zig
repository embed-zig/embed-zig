const glib = @import("glib");
const kcp = @import("../kcp.zig");
const BytesRingBuf = @import("BytesRingBuf.zig");
const PacketRingBuf = @import("PacketRingBuf.zig");

const AddrPort = glib.net.netip.AddrPort;
const ikcp_max_send_segments: usize = 127;
const udp_ring_slots: usize = 64;
const udp_packet_capacity: usize = 2048;
const read_loop_poll_ms: u32 = 100;
const drive_busy_wait_ms: u32 = 1;
const drive_recv_message_limit: usize = 16;
const udp_write_error_backoff = 1 * glib.time.duration.MilliSecond;

pub const Config = struct {
    mtu: u32 = 1400,
    send_window: u32 = 64,
    recv_window: u32 = 64,
    nodelay: i32 = 1,
    interval_ms: i32 = 10,
    resend: i32 = 2,
    no_congestion_control: i32 = 0,
    min_rto_ms: u32 = 80,
    stream: bool = true,
    ack_flush_min_count: usize = 4,
    send_batch_bytes: usize = 8192,
    write_timeout: ?glib.time.duration.Duration = null,
    read_timeout: ?glib.time.duration.Duration = null,
    output_write_timeout: ?glib.time.duration.Duration = null,
    tick_rx_packets: ?usize = 16,
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
        const BytesRing = BytesRingBuf.make(grt);
        const PacketRing = PacketRingBuf.make(grt);

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
        stats_mu: Mutex = .{},
        start_at: glib.time.instant.Time,
        udp_rx: PacketRing,
        udp_tx: PacketRing,
        tx_bytes: BytesRing,
        rx_bytes: BytesRing,
        mu: Mutex = .{},
        session_cond: Condition = .{},
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
                .udp_rx = .{},
                .udp_tx = .{},
                .tx_bytes = .{},
                .rx_bytes = .{},
            };
        }

        fn initKcp(self: *Self, conv: u32, segment_pool: *SegmentPool) !void {
            const allocator = self.allocator;
            const config = self.config;

            try self.udp_rx.init(allocator, udp_ring_slots, udp_packet_capacity);
            errdefer self.udp_rx.deinit(allocator);
            try self.udp_tx.init(allocator, udp_ring_slots, udp_packet_capacity);
            errdefer self.udp_tx.deinit(allocator);
            try self.tx_bytes.init(allocator, config.tx_buffer_capacity);
            errdefer self.tx_bytes.deinit(allocator);
            try self.rx_bytes.init(allocator, config.rx_buffer_capacity);
            errdefer self.rx_bytes.deinit(allocator);
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
            self.rx_bytes.deinit(self.allocator);
            self.tx_bytes.deinit(self.allocator);
            self.udp_tx.deinit(self.allocator);
            self.udp_rx.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn write(self: *Self, buf: []const u8) !usize {
            if (buf.len == 0) return 0;

            const started = grt.time.instant.now();
            var offset: usize = 0;
            try self.checkOpen();
            self.bumpStat("write_calls");
            while (offset < buf.len) {
                try self.checkOpen();
                const queued = self.tx_bytes.writeNoWait(buf[offset..]);
                if (queued > 0) {
                    offset += queued;
                    self.session_cond.signal();
                    continue;
                }

                if (self.writeTimedOut(started)) {
                    if (offset > 0) return offset;
                    const state = self.debugState();
                    const stats = self.statsSnapshot();
                    const driver_err = self.driverErr();
                    std.log.scoped(.kcp_session).err(
                        "write timeout offset={d}/{d} tx={d} rx={d} ws={d} room={d} out={d} in={d} tick={d} queue={d} update={d} read_from={d} driver_err={s}",
                        .{
                            offset,
                            buf.len,
                            self.tx_bytes.len(),
                            self.rx_bytes.len(),
                            state.waitsnd,
                            state.room,
                            stats.udp_out_packets,
                            stats.udp_in_packets,
                            stats.tick_calls,
                            stats.queue_calls,
                            stats.update_calls,
                            stats.read_from_calls,
                            if (driver_err) |err| @errorName(err) else "null",
                        },
                    );
                    return error.KcpSessionWriteTimeout;
                }

                self.bumpStat("write_wait_calls");
                self.logWriteWait(offset, buf.len);
                self.waitLocked(started, self.config.write_timeout);
            }
            return offset;
        }

        pub fn read(self: *Self, buf: []u8) !usize {
            if (buf.len == 0) return 0;
            if (self.isClosed() and self.rx_bytes.len() == 0) return error.KcpSessionClosed;
            if (self.driverErr()) |err| return err;
            const n = self.rx_bytes.read(buf);
            if (n > 0) self.session_cond.signal();
            return n;
        }

        pub fn tick(self: *Self) !u32 {
            self.mu.lock();
            defer self.mu.unlock();
            self.wakeAllWaiters();
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

        pub fn writeLoop(self: *Self, stop: *AtomicBool) !void {
            var frame_storage: [udp_packet_capacity]u8 = undefined;
            while (!stop.load(.acquire)) {
                if (self.isClosed() and self.udpTxLen() == 0) return;
                const frame = self.waitAndPopUdpTxPacket(&frame_storage, stop);
                if (frame.len == 0) continue;
                self.writePacketNow(frame) catch |err| {
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
            self.bumpStat("close_calls");
            self.wakeAllWaiters();
            self.pc.close();
        }

        pub fn resetStats(self: *Self) void {
            self.stats_mu.lock();
            defer self.stats_mu.unlock();
            self.stats = .{};
        }

        pub fn debugState(self: *Self) DebugState {
            self.mu.lock();
            defer self.mu.unlock();
            return self.last_debug_state;
        }

        pub fn pendingBytes(self: *Self) usize {
            return self.tx_bytes.len() + self.rx_bytes.len() + self.debugState().waitsnd;
        }

        pub fn snapshot(self: *Self) Snapshot {
            const stats = self.statsSnapshot();
            const state = self.debugState();
            const tx_len = self.tx_bytes.len();
            const rx_len = self.rx_bytes.len();
            return .{
                .stats = stats,
                .state = state,
                .tx_bytes = tx_len,
                .rx_bytes = rx_len,
                .pending_bytes = tx_len + rx_len + state.waitsnd,
            };
        }

        fn driveOnce(self: *Self) !void {
            self.bumpStat("tick_calls");
            var progressed = false;
            const tick_started = grt.time.instant.now();
            if (try self.drainUdpRingToKcp(self.tickRxLimit()) > 0) progressed = true;
            if (try self.drainKcpRecvToRxRing(drive_recv_message_limit) > 0) progressed = true;
            if (try self.drainTxRingToKcp()) progressed = true;
            if (self.shouldUpdateNow()) {
                try self.updateInner();
                progressed = true;
            }
            if (try self.drainKcpRecvToRxRing(drive_recv_message_limit) > 0) progressed = true;
            self.recordPending();
            const wait_ms = self.nextWaitMs();
            self.logDriveState(progressed, wait_ms);
            if (self.hasImmediateWork()) {
                self.waitForDriveRound(driveBusyWaitDuration());
            } else {
                const wait_duration = self.remainingInterval(tick_started, wait_ms);
                self.waitForDriveWork(wait_duration);
            }
        }

        fn drainTxRingToKcp(self: *Self) !bool {
            var progressed = false;
            while (self.canQueue()) {
                const span = self.tx_bytes.readSpan(self.kcpSendBatchLimit());
                if (span.len == 0) break;
                const rc = kcp.send(self.inst, @ptrCast(span.ptr), @intCast(span.len));
                if (rc < 0) return error.KcpSessionSendFailed;
                self.tx_bytes.discard(span.len);
                self.session_cond.broadcast();
                self.bumpStat("queue_calls");
                progressed = true;
            }
            return progressed;
        }

        fn drainKcpRecvToRxRing(self: *Self, max_messages: usize) !usize {
            var count: usize = 0;
            while (count < max_messages) {
                const peek_size = self.kcpRecvPeekSizeLocked();
                if (peek_size == 0 or self.rx_bytes.space() < peek_size) break;
                const reservation = self.rx_bytes.reserveWriteSpan() orelse break;
                const span = reservation.buf;
                if (span.len < peek_size) {
                    self.rx_bytes.releaseWriteSpan();
                    break;
                }
                const n = kcp.recv(self.inst, @ptrCast(span.ptr), @intCast(span.len));
                if (n <= 0) {
                    self.rx_bytes.releaseWriteSpan();
                    break;
                }
                self.rx_bytes.commitWriteSpan(@intCast(n));
                count += 1;
            }
            return count;
        }

        fn readOnce(self: *Self) !void {
            const reservation = self.udp_rx.reserveWrite();
            if (reservation == null) {
                self.waitForUdpSlot();
                return;
            }
            const reserved = reservation.?;
            self.pc.setReadDeadline(glib.time.instant.add(grt.time.instant.now(), readLoopDuration()));
            const result = self.pc.readFrom(reserved.buf) catch |err| {
                self.udp_rx.releaseWrite();
                switch (err) {
                    error.TimedOut => return,
                    error.Closed => {
                        self.closeFromReadLoop();
                        return;
                    },
                    else => return err,
                }
            };
            if (!self.udp_rx.commitWrite(reserved, result.bytes_read)) {
                self.bumpStat("udp_ring_dropped_packets");
            }
            self.bumpStat("read_from_calls");
            self.session_cond.signal();
        }

        fn drainUdpRingToKcp(self: *Self, max_packets: ?usize) !usize {
            var input_count: usize = 0;
            var flush_pending_ack = false;
            self.bumpStat("pump_calls");

            while (true) {
                var frame_storage: [udp_packet_capacity]u8 = undefined;
                const frame_len = self.udp_rx.popNoWait(&frame_storage) orelse break;
                const frame = frame_storage[0..frame_len];
                if (frame.len >= kcp.OVERHEAD and readLe32(frame) == self.inst.*.conv) {
                    self.inst.*.current = self.nowMs();
                    const rc = kcp.input(self.inst, @ptrCast(frame.ptr), @intCast(frame.len));
                    if (rc < 0) return error.KcpSessionInputFailed;
                    if (self.ackCountInner() > 0 and self.pending_ack_since_ms == null) {
                        self.pending_ack_since_ms = self.nowMs();
                    }
                    if (self.ackCountInner() > 0) flush_pending_ack = true;
                    self.bumpStat("udp_in_packets");
                }
                self.session_cond.signal();

                try self.checkOutput();
                input_count += 1;
                if (max_packets) |limit| {
                    if (input_count >= limit) break;
                }
            }

            if (flush_pending_ack and self.shouldFlushAckNow()) {
                self.bumpStat("pump_flush_ack_calls");
                try self.flushAckInner();
            }

            return input_count;
        }

        fn hasImmediateWork(self: *Self) bool {
            self.mu.lock();
            defer self.mu.unlock();
            return self.hasImmediateWorkLocked();
        }

        fn hasImmediateWorkLocked(self: *Self) bool {
            return self.udp_rx.len() > 0 or
                (self.tx_bytes.len() > 0 and self.canQueue()) or
                self.canDrainKcpRecvLocked();
        }

        fn canDrainKcpRecvLocked(self: *Self) bool {
            const peek_size = self.kcpRecvPeekSizeLocked();
            return peek_size > 0 and
                self.rx_bytes.space() >= peek_size and
                self.rx_bytes.contiguousWriteCapacity() >= peek_size;
        }

        fn kcpRecvPeekSizeLocked(self: *Self) usize {
            const size = kcp.peeksize(self.inst);
            if (size <= 0) return 0;
            return @intCast(size);
        }

        fn waitForDriveWork(self: *Self, duration: glib.time.duration.Duration) void {
            if (duration == 0) return;
            self.mu.lock();
            defer self.mu.unlock();
            if (self.closed or self.driver_err != null) return;
            if (self.hasImmediateWorkLocked()) return;
            self.session_cond.timedWait(&self.mu, @intCast(duration)) catch {};
        }

        fn waitForDriveRound(self: *Self, duration: glib.time.duration.Duration) void {
            if (duration == 0) return;
            self.mu.lock();
            defer self.mu.unlock();
            if (self.closed or self.driver_err != null) return;
            self.session_cond.timedWait(&self.mu, @intCast(duration)) catch {};
        }

        fn waitForUdpSlot(self: *Self) void {
            if (self.isClosed() or self.driverErr() != null) return;
            self.udp_rx.waitForSpace(readLoopDuration()) catch {};
        }

        fn waitAndPopUdpTxPacket(self: *Self, out: *[udp_packet_capacity]u8, stop: *AtomicBool) []const u8 {
            while (!stop.load(.acquire)) {
                const len = self.udp_tx.pop(out, readLoopDuration()) catch continue;
                if (len > 0) return out[0..len];
                if (self.isClosed() or self.driverErr() != null) break;
            }
            return out[0..0];
        }

        fn udpTxLen(self: *Self) usize {
            return self.udp_tx.len();
        }

        fn closeFromReadLoop(self: *Self) void {
            self.mu.lock();
            defer self.mu.unlock();
            self.closed = true;
            self.wakeAllWaiters();
        }

        fn updateInner(self: *Self) !void {
            self.bumpStat("update_calls");
            self.inst.*.current = self.nowMs();
            kcp.update(self.inst, self.inst.*.current);
            try self.checkOutput();
            self.clearPendingAckIfFlushed();
        }

        fn flushAckInner(self: *Self) !void {
            if (self.ackCountInner() == 0) return;
            self.bumpStat("flush_ack_calls");
            try self.flushInner();
            self.pending_ack_since_ms = null;
        }

        fn flushInner(self: *Self) !void {
            self.bumpStat("flush_calls");
            self.inst.*.current = self.nowMs();
            kcp.flush(self.inst);
            try self.checkOutput();
            self.clearPendingAckIfFlushed();
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
            self.recordMaxWaitsnd(pending);
            self.mu.lock();
            defer self.mu.unlock();
            self.last_debug_state = state;
        }

        fn statsSnapshot(self: *Self) Stats {
            self.stats_mu.lock();
            defer self.stats_mu.unlock();
            return self.stats;
        }

        fn bumpStat(self: *Self, comptime field: []const u8) void {
            self.stats_mu.lock();
            defer self.stats_mu.unlock();
            @field(self.stats, field) +%= 1;
        }

        fn recordMaxWaitsnd(self: *Self, pending: u32) void {
            self.stats_mu.lock();
            defer self.stats_mu.unlock();
            if (pending > self.stats.max_waitsnd) self.stats.max_waitsnd = pending;
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

        fn checkOpen(self: *Self) !void {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.closed) return error.KcpSessionClosed;
            if (self.driver_err) |err| return err;
        }

        fn driverErr(self: *Self) ?anyerror {
            self.mu.lock();
            defer self.mu.unlock();
            return self.driver_err;
        }

        fn setDriverErr(self: *Self, err: anyerror) void {
            self.mu.lock();
            defer self.mu.unlock();
            self.driver_err = err;
            self.wakeAllWaiters();
        }

        fn wakeAllWaiters(self: *Self) void {
            self.session_cond.broadcast();
            self.udp_rx.wakeAll();
            self.udp_tx.wakeAll();
            self.tx_bytes.wakeAll();
            self.rx_bytes.wakeAll();
        }

        fn waitLocked(self: *Self, started: glib.time.instant.Time, timeout: ?glib.time.duration.Duration) void {
            self.mu.lock();
            defer self.mu.unlock();
            if (timeout) |duration| {
                const elapsed = glib.time.instant.sub(grt.time.instant.now(), started);
                if (elapsed >= duration) return;
                const remaining: u64 = @intCast(duration - elapsed);
                if (self.tx_bytes.space() > 0) return;
                self.session_cond.timedWait(&self.mu, @min(remaining, 10 * glib.time.duration.MilliSecond)) catch {};
            } else {
                if (self.tx_bytes.space() > 0) return;
                self.session_cond.wait(&self.mu);
            }
        }

        fn nowMs(self: *const Self) u32 {
            const elapsed = glib.time.instant.sub(grt.time.instant.now(), self.start_at);
            if (elapsed <= 0) return 0;
            return @truncate(@as(u64, @intCast(@divTrunc(elapsed, glib.time.duration.MilliSecond))));
        }

        fn canQueue(self: *const Self) bool {
            return self.waitsndInner() < self.sendWindow();
        }

        fn waitsndInner(self: *const Self) u32 {
            const pending = kcp.waitsnd(self.inst);
            if (pending <= 0) return 0;
            return @intCast(pending);
        }

        fn sendRoomInner(self: *const Self) u32 {
            const pending = self.waitsndInner();
            const limit = self.sendWindow();
            if (pending >= limit) return 0;
            return limit - pending;
        }

        fn sendWindow(self: *const Self) u32 {
            return @max(self.inst.*.snd_wnd, 1);
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
            if (timeReached(now_ms, next_ms)) return 0;
            const interval_ms: u32 = @intCast(@max(self.config.interval_ms, 1));
            return @min(next_ms - now_ms, interval_ms);
        }

        fn shouldUpdateNow(self: *const Self) bool {
            const now_ms = self.nowMs();
            const next_ms: u32 = @intCast(kcp.check(self.inst, now_ms));
            return timeReached(now_ms, next_ms);
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
                return self.session.enqueueOutputPacket(buf, len);
            }
        };

        fn enqueueOutputPacket(self: *Self, buf: [*c]const u8, len: c_int) c_int {
            if (len < 0) {
                self.output_err = error.KcpSessionNegativePacketLength;
                return -1;
            }
            const frame = buf[0..@intCast(len)];
            if (frame.len > udp_packet_capacity) {
                self.output_err = error.KcpSessionUdpPacketTooLarge;
                return -1;
            }
            while (true) {
                if (self.isClosed()) {
                    self.output_err = error.KcpSessionClosed;
                    return -1;
                }
                if (self.driverErr()) |err| {
                    self.output_err = err;
                    return -1;
                }
                self.udp_tx.push(frame, 10 * glib.time.duration.MilliSecond) catch |err| switch (err) {
                    error.TimedOut => continue,
                    error.PacketTooLarge => {
                        self.output_err = error.KcpSessionUdpPacketTooLarge;
                        return -1;
                    },
                };
                return @intCast(frame.len);
            }
        }

        fn writePacketNow(self: *Self, frame: []const u8) !void {
            const write_start = if (self.config.output_write_timeout != null) grt.time.instant.now() else 0;
            self.bumpStat("write_to_calls");
            if (self.config.output_write_timeout) |timeout| {
                self.pc.setWriteDeadline(glib.time.instant.add(write_start, timeout));
            }
            defer if (self.config.output_write_timeout != null) self.pc.setWriteDeadline(null);

            const written = self.pc.writeTo(frame, self.remote) catch |err| switch (err) {
                error.TimedOut => {
                    const stats = self.recordUdpWriteTimeout();
                    std.log.scoped(.kcp_session).warn(
                        "udp timeout len={d} out={d} in={d} drop={d}",
                        .{ frame.len, stats.udp_out_packets, stats.udp_in_packets, stats.udp_dropped_packets },
                    );
                    grt.time.sleep(udp_write_error_backoff);
                    return;
                },
                error.Closed, error.MessageTooLong => return err,
                else => {
                    const stats = self.recordUdpDrop();
                    std.log.scoped(.kcp_session).warn(
                        "udp err={s} len={d} out={d} in={d} drop={d}",
                        .{ @errorName(err), frame.len, stats.udp_out_packets, stats.udp_in_packets, stats.udp_dropped_packets },
                    );
                    return err;
                },
            };
            if (written != frame.len) {
                const stats = self.statsSnapshot();
                std.log.scoped(.kcp_session).warn(
                    "udp short wr={d} len={d} out={d} in={d}",
                    .{ written, frame.len, stats.udp_out_packets, stats.udp_in_packets },
                );
                return error.ShortKcpSessionUdpWrite;
            }
            self.recordUdpOut(frame.len);
        }

        fn recordUdpOut(self: *Self, frame_len: usize) void {
            const len: u32 = @intCast(frame_len);
            self.stats_mu.lock();
            defer self.stats_mu.unlock();
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

        fn recordUdpDrop(self: *Self) Stats {
            self.stats_mu.lock();
            defer self.stats_mu.unlock();
            self.stats.udp_dropped_packets +%= 1;
            return self.stats;
        }

        fn recordUdpWriteTimeout(self: *Self) Stats {
            self.stats_mu.lock();
            defer self.stats_mu.unlock();
            self.stats.write_to_timeouts +%= 1;
            self.stats.udp_dropped_packets +%= 1;
            return self.stats;
        }

        fn logWriteWait(self: *Self, offset: usize, total: usize) void {
            const now_ms = self.nowMs();
            if (!self.shouldLogWriteWait(now_ms)) return;
            const state = self.debugState();
            const tx_len = self.tx_bytes.len();
            const rx_len = self.rx_bytes.len();
            const stats = self.statsSnapshot();
            std.log.scoped(.kcp_session).info(
                "ww {d}/{d} tx={d} rx={d} ws={d} room={d} cw={d} rw={d} eff={d} infl={d} una={d} nxt={d} sq={d} sb={d} rq={d} rb={d} rto={d} ss={d} xmit={d} out={d} in={d}",
                .{
                    offset,
                    total,
                    tx_len,
                    rx_len,
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
                    stats.udp_out_packets,
                    stats.udp_in_packets,
                },
            );
        }

        fn shouldLogWriteWait(self: *Self, now_ms: u32) bool {
            self.mu.lock();
            defer self.mu.unlock();
            if (now_ms -% self.last_write_wait_log_ms < 1000) return false;
            self.last_write_wait_log_ms = now_ms;
            return true;
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

fn timeReached(now_ms: u32, target_ms: u32) bool {
    return @as(i32, @bitCast(now_ms -% target_ms)) >= 0;
}

fn readLoopDuration() glib.time.duration.Duration {
    return @as(glib.time.duration.Duration, read_loop_poll_ms) * glib.time.duration.MilliSecond;
}

fn driveBusyWaitDuration() glib.time.duration.Duration {
    return @as(glib.time.duration.Duration, drive_busy_wait_ms) * glib.time.duration.MilliSecond;
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
            _ = make(grt);
        }
    }.run);
}
