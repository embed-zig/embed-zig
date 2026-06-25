//! Netconn-like owner around ikcp.
//!
//! Public read/write and packet input serialize ikcp through one mutex. The session
//! task only drives ikcp's timer.

const glib = @import("glib");
const kcp = @import("../kcp.zig");

pub const Mode = enum {
    packet,
    stream,
};

pub const Config = struct {
    mtu: usize = 1400,
    mode: Mode = .stream,
    nodelay: i32 = 1,
    interval_ms: i32 = 10,
    resend: i32 = 2,
    no_congestion_control: i32 = 1,
    send_window: u32 = 32,
    recv_window: u32 = 32,
    min_rto_ms: u32 = 80,
};

pub const PacketBearer = struct {
    ctx: ?*anyopaque = null,
    writePacket: *const fn (ctx: ?*anyopaque, datagram: []const u8) anyerror!void,

    pub fn write(self: PacketBearer, datagram: []const u8) !void {
        try self.writePacket(self.ctx, datagram);
    }
};

pub const Output = PacketBearer;

const default_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };

pub fn make(comptime grt: type) type {
    const std = grt.std;
    const Mutex = grt.sync.Mutex;
    const Condition = grt.sync.Condition;
    const SegmentPool = kcp.SegmentPool.make(grt);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        inst: *kcp.Kcp,
        segment_pool: SegmentPool,
        bearer: PacketBearer,
        output_ctx: OutputContext,
        output_err: ?anyerror = null,
        start_at: glib.time.instant.Time,
        kcp_mutex: Mutex = .{},
        read_cond: Condition = .{},
        write_cond: Condition = .{},
        stopping: bool = false,
        running: bool = false,
        task_handle: ?grt.task.Handle = null,
        task_err: ?anyerror = null,
        pending_segments: usize = 0,
        cached_snapshot: Snapshot = .{},
        input_packets_total: u64 = 0,
        input_errors_total: u64 = 0,
        output_packets_total: u64 = 0,
        output_bytes_total: u64 = 0,
        output_drops_total: u64 = 0,
        loop_count: u64 = 0,
        loop_sleep_count: u64 = 0,
        loop_sleep_ns_total: u64 = 0,
        loop_zero_sleep_count: u64 = 0,
        loop_work_ns_total: u64 = 0,
        loop_work_ns_max: u64 = 0,
        loop_late_ns_max: u64 = 0,
        loop_lock_wait_ns_total: u64 = 0,
        loop_lock_wait_ns_max: u64 = 0,
        loop_update_ns_total: u64 = 0,
        loop_update_ns_max: u64 = 0,
        loop_update_max_output_burst: u32 = 0,
        loop_update_max_output_callback_ns_total: u64 = 0,
        loop_update_max_output_callback_ns_max: u64 = 0,
        loop_update_max_output_write_ns_total: u64 = 0,
        loop_update_max_output_write_ns_max: u64 = 0,
        loop_update_max_internal_ns: u64 = 0,
        loop_post_ns_total: u64 = 0,
        loop_post_ns_max: u64 = 0,
        current_output_callback_ns_total: u64 = 0,
        current_output_callback_ns_max: u64 = 0,
        current_output_write_ns_total: u64 = 0,
        current_output_write_ns_max: u64 = 0,
        current_output_burst: u32 = 0,
        last_output_burst: u32 = 0,
        max_output_burst: u32 = 0,
        config: Config,

        pub const Snapshot = struct {
            waitsnd: usize = 0,
            tx_bytes: usize = 0,
            tx_room: usize = 0,
            rx_bytes: usize = 0,
            rx_room: usize = 0,
            input_queue: usize = 0,
            input_room: usize = 0,
            snd_queue: u32 = 0,
            snd_buf: u32 = 0,
            rcv_queue: u32 = 0,
            rcv_buf: u32 = 0,
            rmt_wnd: u32 = 0,
            cwnd: u32 = 0,
            rx_rto: i32 = 0,
            rx_srtt: i32 = 0,
            rx_rttval: i32 = 0,
            xmit: u32 = 0,
            input_packets: u64 = 0,
            input_errors: u64 = 0,
            output_packets: u64 = 0,
            output_bytes: u64 = 0,
            output_drops: u64 = 0,
            loop_count: u64 = 0,
            loop_sleep_count: u64 = 0,
            loop_sleep_ms: u64 = 0,
            loop_zero_sleep_count: u64 = 0,
            loop_work_us: u64 = 0,
            loop_work_max_us: u64 = 0,
            loop_late_max_us: u64 = 0,
            loop_lock_wait_us: u64 = 0,
            loop_lock_wait_max_us: u64 = 0,
            loop_update_us: u64 = 0,
            loop_update_max_us: u64 = 0,
            loop_update_max_output_burst: u32 = 0,
            loop_update_max_output_callback_us: u64 = 0,
            loop_update_max_output_callback_max_us: u64 = 0,
            loop_update_max_output_write_us: u64 = 0,
            loop_update_max_output_write_max_us: u64 = 0,
            loop_update_max_internal_us: u64 = 0,
            loop_post_us: u64 = 0,
            loop_post_max_us: u64 = 0,
            last_output_burst: u32 = 0,
            max_output_burst: u32 = 0,
            output_new_segments: u32 = 0,
            output_fast_segments: u32 = 0,
            output_rto_segments: u32 = 0,
            output_ack_segments: u32 = 0,
            output_wask_segments: u32 = 0,
            output_wins_segments: u32 = 0,
            input_ack_segments: u32 = 0,
            input_push_segments: u32 = 0,
            pool_available_segments: usize = 0,
            pool_reserved_segments: usize = 0,
            pool_pooled_allocs: usize = 0,
            pool_pooled_frees: usize = 0,
            pool_fallback_allocs: usize = 0,
            pool_fallback_frees: usize = 0,
            pool_allocation_failures: usize = 0,
        };

        pub fn init(
            self: *Self,
            allocator: std.mem.Allocator,
            conv: u32,
            config: Config,
            bearer: PacketBearer,
        ) !void {
            if (config.mtu <= kcp.OVERHEAD) return error.KcpSessionInvalidMtu;
            if (config.send_window == 0 or config.recv_window == 0) return error.KcpSessionInvalidWindow;

            const mss = config.mtu - kcp.OVERHEAD;
            var segment_pool = try SegmentPool.init(
                allocator,
                mss,
                @as(usize, config.send_window) + @as(usize, config.recv_window),
            );
            errdefer segment_pool.deinit();

            self.* = .{
                .allocator = allocator,
                .inst = undefined,
                .segment_pool = segment_pool,
                .bearer = bearer,
                .output_ctx = undefined,
                .start_at = grt.time.instant.now(),
                .config = config,
            };
            self.output_ctx = .{ .session = self };

            self.inst = kcp.createWithAllocator(conv, &self.output_ctx, self.segment_pool.allocator()) orelse {
                return error.KcpSessionCreateFailed;
            };
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
            if (config.min_rto_ms > std.math.maxInt(c_int)) return error.KcpSessionInvalidMinRto;
            self.inst.*.rx_minrto = @intCast(config.min_rto_ms);
            if (self.inst.*.rx_rto < self.inst.*.rx_minrto) self.inst.*.rx_rto = self.inst.*.rx_minrto;
            self.inst.*.stream = if (config.mode == .stream) 1 else 0;
        }

        pub fn start(self: *Self, options: glib.task.Options) !void {
            self.kcp_mutex.lock();
            defer self.kcp_mutex.unlock();
            if (self.running) return error.KcpSessionAlreadyStarted;
            self.stopping = false;
            self.task_err = null;
            self.running = true;
            errdefer {
                self.running = false;
                self.task_handle = null;
            }
            self.task_handle = try grt.task.go("kcp/session", options, glib.task.Routine.init(self, driveLoopTask));
        }

        pub fn startDefault(self: *Self) !void {
            try self.start(default_task_options);
        }

        pub fn stop(self: *Self) void {
            self.kcp_mutex.lock();
            const handle = self.task_handle;
            const should_join = self.running;
            self.stopping = true;
            self.read_cond.broadcast();
            self.write_cond.broadcast();
            self.kcp_mutex.unlock();

            if (should_join) {
                if (handle) |task| task.join();
            }

            self.kcp_mutex.lock();
            self.running = false;
            self.task_handle = null;
            self.read_cond.broadcast();
            self.write_cond.broadcast();
            self.kcp_mutex.unlock();
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            kcp.release(self.inst);
            self.segment_pool.deinit();
            self.* = undefined;
        }

        pub fn inputPacket(self: *Self, datagram: []const u8) !void {
            self.kcp_mutex.lock();
            defer self.kcp_mutex.unlock();
            if (self.stopping) return error.Closed;

            const rc = kcp.input(self.inst, datagram.ptr, datagram.len);
            if (rc < 0) {
                self.input_errors_total +%= 1;
                self.updateCachedStateLocked();
                return;
            }
            self.input_packets_total +%= 1;
            self.beginOutputBurst();
            kcp.flush(self.inst);
            try self.checkOutputLocked();
            self.updateCachedStateLocked();
        }

        pub fn inputDatagram(self: *Self, datagram: []const u8) !void {
            try self.inputPacket(datagram);
        }

        pub fn write(self: *Self, payload: []const u8) !usize {
            return self.writeWithTimeout(payload, null);
        }

        pub fn writeTimeout(self: *Self, payload: []const u8, timeout: glib.time.duration.Duration) !usize {
            return self.writeWithTimeout(payload, timeout);
        }

        pub fn read(self: *Self, buf: []u8) !usize {
            return self.readWithTimeout(buf, null);
        }

        pub fn readTimeout(self: *Self, buf: []u8, timeout: glib.time.duration.Duration) !usize {
            return self.readWithTimeout(buf, timeout);
        }

        pub fn close(self: *Self) void {
            self.stop();
        }

        pub fn waitsnd(self: *const Self) usize {
            const mutable: *Self = @constCast(self);
            mutable.kcp_mutex.lock();
            defer mutable.kcp_mutex.unlock();
            const pending = kcp.waitsnd(mutable.inst);
            return if (pending <= 0) 0 else @intCast(pending);
        }

        pub fn snapshot(self: *const Self) Snapshot {
            const mutable: *Self = @constCast(self);
            mutable.kcp_mutex.lock();
            defer mutable.kcp_mutex.unlock();
            mutable.updateCachedStateLocked();
            return mutable.cached_snapshot;
        }

        pub fn checkTaskError(self: *Self) !void {
            self.kcp_mutex.lock();
            defer self.kcp_mutex.unlock();
            if (self.task_err) |err| return err;
        }

        fn driveLoopTask(self: *Self) void {
            self.driveLoop() catch |err| {
                std.log.scoped(.kcp_session).err("drive loop failed: {s}", .{@errorName(err)});
                self.kcp_mutex.lock();
                self.task_err = err;
                self.stopping = true;
                self.read_cond.broadcast();
                self.write_cond.broadcast();
                self.kcp_mutex.unlock();
            };
        }

        fn driveLoop(self: *Self) !void {
            var next_tick = glib.time.instant.add(grt.time.instant.now(), self.intervalDuration());

            while (true) {
                const loop_start = grt.time.instant.now();
                self.kcp_mutex.lock();
                const lock_acquired = grt.time.instant.now();
                if (self.stopping) {
                    self.kcp_mutex.unlock();
                    return;
                }

                self.beginOutputBurst();
                kcp.update(self.inst, self.nowMs());
                const update_end = grt.time.instant.now();
                self.checkOutputLocked() catch |err| {
                    self.kcp_mutex.unlock();
                    return err;
                };
                self.updateCachedStateLocked();
                self.read_cond.broadcast();
                self.write_cond.broadcast();

                const work_end = grt.time.instant.now();
                self.loop_count +%= 1;
                const lock_wait_ns = positiveDurationNs(glib.time.instant.sub(lock_acquired, loop_start));
                self.loop_lock_wait_ns_total +%= lock_wait_ns;
                self.loop_lock_wait_ns_max = @max(self.loop_lock_wait_ns_max, lock_wait_ns);
                const update_ns = positiveDurationNs(glib.time.instant.sub(update_end, lock_acquired));
                self.loop_update_ns_total +%= update_ns;
                if (update_ns > self.loop_update_ns_max) {
                    self.loop_update_ns_max = update_ns;
                    self.loop_update_max_output_burst = self.current_output_burst;
                    self.loop_update_max_output_callback_ns_total = self.current_output_callback_ns_total;
                    self.loop_update_max_output_callback_ns_max = self.current_output_callback_ns_max;
                    self.loop_update_max_output_write_ns_total = self.current_output_write_ns_total;
                    self.loop_update_max_output_write_ns_max = self.current_output_write_ns_max;
                    self.loop_update_max_internal_ns = update_ns -| self.current_output_callback_ns_total;
                }
                const post_ns = positiveDurationNs(glib.time.instant.sub(work_end, update_end));
                self.loop_post_ns_total +%= post_ns;
                self.loop_post_ns_max = @max(self.loop_post_ns_max, post_ns);
                const work_ns = positiveDurationNs(glib.time.instant.sub(work_end, loop_start));
                self.loop_work_ns_total +%= work_ns;
                self.loop_work_ns_max = @max(self.loop_work_ns_max, work_ns);

                const wait_ns = glib.time.instant.sub(next_tick, work_end);
                if (wait_ns > 0 and !self.stopping) {
                    self.kcp_mutex.unlock();
                    const sleep_start = grt.time.instant.now();
                    grt.time.sleep(wait_ns);
                    const sleep_ns = positiveDurationNs(glib.time.instant.sub(grt.time.instant.now(), sleep_start));
                    self.kcp_mutex.lock();
                    self.loop_sleep_count +%= 1;
                    self.loop_sleep_ns_total +%= sleep_ns;
                    next_tick = glib.time.instant.add(next_tick, self.intervalDuration());
                    self.kcp_mutex.unlock();
                    continue;
                }
                if (wait_ns <= 0) {
                    self.loop_zero_sleep_count +%= 1;
                    self.loop_late_ns_max = @max(self.loop_late_ns_max, glib.time.duration.magnitude(wait_ns));
                    const now = grt.time.instant.now();
                    next_tick = now;
                }
                next_tick = glib.time.instant.add(next_tick, self.intervalDuration());
                self.kcp_mutex.unlock();
            }
        }

        fn writeWithTimeout(self: *Self, payload: []const u8, timeout: ?glib.time.duration.Duration) !usize {
            if (payload.len == 0) return 0;
            const deadline = makeDeadline(timeout);

            self.kcp_mutex.lock();
            defer self.kcp_mutex.unlock();
            while (true) {
                if (self.stopping) return error.Closed;
                const admitted = @min(payload.len, self.sendAdmissionBytesLocked());
                if (admitted != 0) {
                    const n = @min(admitted, @as(usize, @intCast(std.math.maxInt(c_int))));
                    const rc = kcp.send(self.inst, payload[0..n].ptr, @intCast(n));
                    if (rc < 0) return error.KcpSessionSendFailed;
                    self.updateCachedStateLocked();
                    return n;
                }
                try self.waitForWriteLocked(deadline);
            }
        }

        fn readWithTimeout(self: *Self, buf: []u8, timeout: ?glib.time.duration.Duration) !usize {
            if (buf.len == 0) return 0;
            const deadline = makeDeadline(timeout);

            self.kcp_mutex.lock();
            defer self.kcp_mutex.unlock();
            while (true) {
                if (self.stopping) return error.Closed;
                const peek = kcp.peeksize(self.inst);
                if (peek <= 0) {
                    try self.waitForReadLocked(deadline);
                    continue;
                }
                const recv_len = @min(@as(usize, @intCast(peek)), buf.len);
                const rc = kcp.recv(self.inst, buf[0..recv_len].ptr, @intCast(recv_len));
                if (rc < 0) return error.KcpSessionReceiveFailed;
                const received: usize = @intCast(rc);
                if (received == 0) {
                    try self.waitForReadLocked(deadline);
                    continue;
                }
                self.updateCachedStateLocked();
                return received;
            }
        }

        fn updateCachedStateLocked(self: *Self) void {
            const pending = kcp.waitsnd(self.inst);
            const peek = kcp.peeksize(self.inst);
            const pool = self.segment_pool.snapshot();
            const snap = Snapshot{
                .waitsnd = if (pending <= 0) 0 else @intCast(pending),
                .tx_bytes = 0,
                .tx_room = self.sendAdmissionBytesLocked(),
                .rx_bytes = if (peek <= 0) 0 else @intCast(peek),
                .rx_room = 0,
                .input_queue = 0,
                .input_room = 0,
                .snd_queue = self.inst.*.nsnd_que,
                .snd_buf = self.inst.*.nsnd_buf,
                .rcv_queue = self.inst.*.nrcv_que,
                .rcv_buf = self.inst.*.nrcv_buf,
                .rmt_wnd = self.inst.*.rmt_wnd,
                .cwnd = self.inst.*.cwnd,
                .rx_rto = self.inst.*.rx_rto,
                .rx_srtt = self.inst.*.rx_srtt,
                .rx_rttval = self.inst.*.rx_rttval,
                .xmit = self.inst.*.xmit,
                .input_packets = self.input_packets_total,
                .input_errors = self.input_errors_total,
                .output_packets = self.output_packets_total,
                .output_bytes = self.output_bytes_total,
                .output_drops = self.output_drops_total,
                .loop_count = self.loop_count,
                .loop_sleep_count = self.loop_sleep_count,
                .loop_sleep_ms = self.loop_sleep_ns_total / @as(u64, @intCast(glib.time.duration.MilliSecond)),
                .loop_zero_sleep_count = self.loop_zero_sleep_count,
                .loop_work_us = self.loop_work_ns_total / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .loop_work_max_us = self.loop_work_ns_max / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .loop_late_max_us = self.loop_late_ns_max / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .loop_lock_wait_us = self.loop_lock_wait_ns_total / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .loop_lock_wait_max_us = self.loop_lock_wait_ns_max / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .loop_update_us = self.loop_update_ns_total / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .loop_update_max_us = self.loop_update_ns_max / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .loop_update_max_output_burst = self.loop_update_max_output_burst,
                .loop_update_max_output_callback_us = self.loop_update_max_output_callback_ns_total / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .loop_update_max_output_callback_max_us = self.loop_update_max_output_callback_ns_max / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .loop_update_max_output_write_us = self.loop_update_max_output_write_ns_total / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .loop_update_max_output_write_max_us = self.loop_update_max_output_write_ns_max / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .loop_update_max_internal_us = self.loop_update_max_internal_ns / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .loop_post_us = self.loop_post_ns_total / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .loop_post_max_us = self.loop_post_ns_max / @as(u64, @intCast(glib.time.duration.MicroSecond)),
                .last_output_burst = self.last_output_burst,
                .max_output_burst = self.max_output_burst,
                .output_new_segments = self.inst.*.diag_output_new,
                .output_fast_segments = self.inst.*.diag_output_fast,
                .output_rto_segments = self.inst.*.diag_output_rto,
                .output_ack_segments = self.inst.*.diag_output_ack,
                .output_wask_segments = self.inst.*.diag_output_wask,
                .output_wins_segments = self.inst.*.diag_output_wins,
                .input_ack_segments = self.inst.*.diag_input_ack,
                .input_push_segments = self.inst.*.diag_input_push,
                .pool_available_segments = pool.available_segments,
                .pool_reserved_segments = pool.reserved_segments,
                .pool_pooled_allocs = pool.pooled_allocs,
                .pool_pooled_frees = pool.pooled_frees,
                .pool_fallback_allocs = pool.fallback_allocs,
                .pool_fallback_frees = pool.fallback_frees,
                .pool_allocation_failures = pool.allocation_failures,
            };
            self.pending_segments = snap.waitsnd;
            self.cached_snapshot = snap;
        }

        fn sendAdmissionBytesLocked(self: *Self) usize {
            const pending = kcp.waitsnd(self.inst);
            if (pending < 0) return 0;
            const pending_segments: usize = @intCast(pending);
            if (pending_segments >= self.config.send_window) return 0;
            const remaining_segments = @as(usize, self.config.send_window) - pending_segments;
            const mss = self.config.mtu - kcp.OVERHEAD;
            return remaining_segments * mss;
        }

        fn beginOutputBurst(self: *Self) void {
            self.current_output_burst = 0;
            self.last_output_burst = 0;
            self.current_output_callback_ns_total = 0;
            self.current_output_callback_ns_max = 0;
            self.current_output_write_ns_total = 0;
            self.current_output_write_ns_max = 0;
        }

        fn shouldStop(self: *Self) bool {
            self.kcp_mutex.lock();
            defer self.kcp_mutex.unlock();
            return self.stopping;
        }

        fn nowMs(self: *Self) u32 {
            const elapsed = grt.time.instant.sub(grt.time.instant.now(), self.start_at);
            if (elapsed <= 0) return 0;
            const elapsed_ms = @as(u64, @intCast(@divTrunc(elapsed, glib.time.duration.MilliSecond)));
            return @intCast(@min(elapsed_ms, std.math.maxInt(u32)));
        }

        fn checkOutputLocked(self: *Self) !void {
            if (self.output_err) |err| {
                self.output_err = null;
                return err;
            }
        }

        fn intervalDuration(self: *const Self) glib.time.duration.Duration {
            const interval_ms: glib.time.duration.Duration = if (self.config.interval_ms <= 0) 1 else @intCast(self.config.interval_ms);
            return interval_ms * glib.time.duration.MilliSecond;
        }

        fn positiveDurationNs(duration: glib.time.duration.Duration) u64 {
            return if (duration <= 0) 0 else @intCast(duration);
        }

        fn makeDeadline(timeout: ?glib.time.duration.Duration) ?glib.time.instant.Time {
            const value = timeout orelse return null;
            return glib.time.instant.add(grt.time.instant.now(), value);
        }

        fn waitForReadLocked(self: *Self, deadline: ?glib.time.instant.Time) error{Timeout}!void {
            const value = deadline orelse {
                self.read_cond.wait(&self.kcp_mutex);
                return;
            };
            const remaining = glib.time.instant.sub(value, grt.time.instant.now());
            if (remaining <= 0) return error.Timeout;
            self.read_cond.timedWait(&self.kcp_mutex, @intCast(remaining)) catch return error.Timeout;
        }

        fn waitForWriteLocked(self: *Self, deadline: ?glib.time.instant.Time) error{Timeout}!void {
            const value = deadline orelse {
                self.write_cond.wait(&self.kcp_mutex);
                return;
            };
            const remaining = glib.time.instant.sub(value, grt.time.instant.now());
            if (remaining <= 0) return error.Timeout;
            self.write_cond.timedWait(&self.kcp_mutex, @intCast(remaining)) catch return error.Timeout;
        }

        const OutputContext = struct {
            session: *Self,

            fn output(raw: [*c]const u8, len: c_int, _: [*c]kcp.Kcp, user: ?*anyopaque) callconv(.c) c_int {
                if (len < 0) return -1;
                const callback_start = grt.time.instant.now();
                const ctx: *OutputContext = @ptrCast(@alignCast(user orelse return -1));
                const self = ctx.session;
                const datagram = raw[0..@intCast(len)];
                self.output_packets_total +%= 1;
                self.output_bytes_total +%= datagram.len;
                self.current_output_burst +%= 1;
                self.last_output_burst = self.current_output_burst;
                self.max_output_burst = @max(self.max_output_burst, self.current_output_burst);
                const write_start = grt.time.instant.now();
                self.bearer.write(datagram) catch |err| {
                    const write_ns = positiveDurationNs(grt.time.instant.since(write_start));
                    self.current_output_write_ns_total +%= write_ns;
                    self.current_output_write_ns_max = @max(self.current_output_write_ns_max, write_ns);
                    const callback_ns = positiveDurationNs(grt.time.instant.since(callback_start));
                    self.current_output_callback_ns_total +%= callback_ns;
                    self.current_output_callback_ns_max = @max(self.current_output_callback_ns_max, callback_ns);
                    self.output_drops_total +%= 1;
                    std.log.scoped(.kcp_session).err("output failed: {s} len={d}", .{ @errorName(err), datagram.len });
                    self.output_err = err;
                    return -1;
                };
                const write_ns = positiveDurationNs(grt.time.instant.since(write_start));
                self.current_output_write_ns_total +%= write_ns;
                self.current_output_write_ns_max = @max(self.current_output_write_ns_max, write_ns);
                const callback_ns = positiveDurationNs(grt.time.instant.since(callback_start));
                self.current_output_callback_ns_total +%= callback_ns;
                self.current_output_callback_ns_max = @max(self.current_output_callback_ns_max, callback_ns);
                return len;
            }
        };
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    return glib.testing.TestRunner.fromFn(grt.std, 512 * 1024, struct {
        fn run(_: *glib.testing.T, allocator: grt.std.mem.Allocator) !void {
            const std = grt.std;
            const Session = make(grt);

            const Wire = struct {
                const max_packets = 16;
                const max_packet_size = 2048;

                mutex: grt.sync.Mutex = .{},
                peer: ?*Session = null,
                packets: [max_packets][max_packet_size]u8 = undefined,
                lens: [max_packets]usize = undefined,
                head: usize = 0,
                tail: usize = 0,
                count: usize = 0,

                fn output(ctx: ?*anyopaque, datagram: []const u8) !void {
                    const self: *@This() = @ptrCast(@alignCast(ctx orelse return error.MissingWireContext));
                    if (datagram.len > max_packet_size) return error.PacketTooLarge;
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    if (self.count == max_packets) return error.PacketQueueFull;
                    @memcpy(self.packets[self.tail][0..datagram.len], datagram);
                    self.lens[self.tail] = datagram.len;
                    self.tail = (self.tail + 1) % max_packets;
                    self.count += 1;
                }

                fn setPeer(self: *@This(), peer: *Session) void {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    self.peer = peer;
                }

                fn pumpOne(self: *@This()) !bool {
                    var packet: [max_packet_size]u8 = undefined;
                    var packet_len: usize = 0;
                    var peer: ?*Session = null;

                    self.mutex.lock();
                    if (self.count == 0) {
                        self.mutex.unlock();
                        return false;
                    }
                    peer = self.peer;
                    packet_len = self.lens[self.head];
                    @memcpy(packet[0..packet_len], self.packets[self.head][0..packet_len]);
                    self.head = (self.head + 1) % max_packets;
                    self.count -= 1;
                    self.mutex.unlock();

                    try (peer orelse return error.MissingPeer).inputPacket(packet[0..packet_len]);
                    return true;
                }

                fn pumpAll(self: *@This()) !void {
                    while (try self.pumpOne()) {}
                }
            };

            var a_to_b = Wire{};
            var b_to_a = Wire{};
            var a: Session = undefined;
            try a.init(allocator, 7, .{ .mode = .stream }, .{ .ctx = &a_to_b, .writePacket = Wire.output });
            defer a.deinit();
            var b: Session = undefined;
            try b.init(allocator, 7, .{ .mode = .stream }, .{ .ctx = &b_to_a, .writePacket = Wire.output });
            defer b.deinit();
            a_to_b.setPeer(&b);
            b_to_a.setPeer(&a);

            try a.startDefault();
            try b.startDefault();

            try std.testing.expectEqual(@as(usize, 5), try a.write("hello"));
            var out: [16]u8 = undefined;
            const started = grt.time.instant.now();
            const n = while (glib.time.instant.sub(grt.time.instant.now(), started) < 2 * glib.time.duration.Second) {
                try a_to_b.pumpAll();
                try b_to_a.pumpAll();
                break b.readTimeout(&out, glib.time.duration.MilliSecond) catch |err| switch (err) {
                    error.Timeout => {
                        grt.time.sleep(glib.time.duration.MilliSecond);
                        continue;
                    },
                    else => return err,
                };
            } else return error.KcpSessionTestTimedOut;
            try std.testing.expectEqual(@as(usize, 5), n);
            try std.testing.expectEqualStrings("hello", out[0..5]);
        }
    }.run);
}
