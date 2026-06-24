//! Netconn-like owner around ikcp.
//!
//! Public read/write and packet input only touch mux-owned rings. A single mux
//! task owns the ikcp control block and serializes every ikcp_* call.

const glib = @import("glib");
const kcp = @import("../kcp.zig");
const BytesRingFile = @import("BytesRing.zig");
const PacketRingFile = @import("PacketRing.zig");

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

const default_tx_bytes_capacity: usize = 32 * 1024;
const default_rx_bytes_capacity: usize = 64 * 1024;
const default_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };
const drive_packet_buf_capacity: usize = 2048;
const drive_send_buf_capacity: usize = 8192;
const drive_recv_buf_capacity: usize = 8192;
const cooperative_sleep_interval: usize = 32;
const cooperative_sleep_duration = 1 * glib.time.duration.MilliSecond;

pub fn make(comptime grt: type) type {
    const std = grt.std;
    const Mutex = grt.sync.Mutex;
    const Condition = grt.sync.Condition;
    const SegmentPool = kcp.SegmentPool.make(grt);
    const PacketRing = PacketRingFile.make(grt);
    const BytesRing = BytesRingFile.make(grt);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        inst: *kcp.Kcp,
        segment_pool: SegmentPool,
        input_packets: PacketRing,
        tx_bytes: BytesRing,
        rx_bytes: BytesRing,
        bearer: PacketBearer,
        output_ctx: OutputContext,
        output_err: ?anyerror = null,
        start_at: glib.time.instant.Time,
        wake_mutex: Mutex = .{},
        wake_cond: Condition = .{},
        wake_pending: bool = false,
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
            if (config.mtu <= kcp.OVERHEAD) return error.KcpMuxInvalidMtu;
            if (config.mtu > drive_packet_buf_capacity) return error.KcpMuxMtuTooLarge;
            if (config.send_window == 0 or config.recv_window == 0) return error.KcpMuxInvalidWindow;

            const mss = config.mtu - kcp.OVERHEAD;
            const window_segments = @max(@as(usize, config.send_window), @as(usize, config.recv_window));
            const packet_slots = @max(window_segments, @as(usize, 32));

            var segment_pool = try SegmentPool.init(
                allocator,
                mss,
                @as(usize, config.send_window) + @as(usize, config.recv_window),
            );
            errdefer segment_pool.deinit();

            var input_packets = try PacketRing.init(allocator, packet_slots, config.mtu);
            errdefer input_packets.deinit();
            var tx_bytes = try BytesRing.init(allocator, default_tx_bytes_capacity);
            errdefer tx_bytes.deinit();
            var rx_bytes = try BytesRing.init(allocator, default_rx_bytes_capacity);
            errdefer rx_bytes.deinit();

            self.* = .{
                .allocator = allocator,
                .inst = undefined,
                .segment_pool = segment_pool,
                .input_packets = input_packets,
                .tx_bytes = tx_bytes,
                .rx_bytes = rx_bytes,
                .bearer = bearer,
                .output_ctx = undefined,
                .start_at = grt.time.instant.now(),
                .config = config,
            };
            self.output_ctx = .{ .mux = self };

            self.inst = kcp.createWithAllocator(conv, &self.output_ctx, self.segment_pool.allocator()) orelse {
                return error.KcpMuxCreateFailed;
            };
            errdefer kcp.release(self.inst);

            kcp.setOutput(self.inst, OutputContext.output);
            if (kcp.setMtu(self.inst, @intCast(config.mtu)) != 0) return error.KcpMuxSetMtuFailed;
            if (kcp.nodelay(
                self.inst,
                config.nodelay,
                config.interval_ms,
                config.resend,
                config.no_congestion_control,
            ) != 0) return error.KcpMuxNodelayFailed;
            if (kcp.wndsize(self.inst, @intCast(config.send_window), @intCast(config.recv_window)) != 0) {
                return error.KcpMuxWndsizeFailed;
            }
            if (config.min_rto_ms > std.math.maxInt(c_int)) return error.KcpMuxInvalidMinRto;
            self.inst.*.rx_minrto = @intCast(config.min_rto_ms);
            if (self.inst.*.rx_rto < self.inst.*.rx_minrto) self.inst.*.rx_rto = self.inst.*.rx_minrto;
            self.inst.*.stream = if (config.mode == .stream) 1 else 0;
        }

        pub fn start(self: *Self, options: glib.task.Options) !void {
            self.wake_mutex.lock();
            defer self.wake_mutex.unlock();
            if (self.running) return error.KcpMuxAlreadyStarted;
            self.stopping = false;
            self.wake_pending = false;
            self.task_err = null;
            self.running = true;
            errdefer {
                self.running = false;
                self.task_handle = null;
            }
            self.task_handle = try grt.task.go("kcp/mux", options, glib.task.Routine.init(self, driveLoopTask));
        }

        pub fn startDefault(self: *Self) !void {
            try self.start(default_task_options);
        }

        pub fn stop(self: *Self) void {
            self.wake_mutex.lock();
            const handle = self.task_handle;
            const should_join = self.running;
            self.stopping = true;
            self.wake_pending = true;
            self.wake_cond.broadcast();
            self.wake_mutex.unlock();

            self.input_packets.close();
            self.tx_bytes.close();
            self.rx_bytes.close();

            if (should_join) {
                if (handle) |task| task.join();
            }

            self.wake_mutex.lock();
            self.running = false;
            self.task_handle = null;
            self.wake_mutex.unlock();
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            kcp.release(self.inst);
            self.rx_bytes.deinit();
            self.tx_bytes.deinit();
            self.input_packets.deinit();
            self.segment_pool.deinit();
            self.* = undefined;
        }

        pub fn inputPacket(self: *Self, datagram: []const u8) !void {
            try self.input_packets.pushBlocking(datagram);
            self.wake();
        }

        pub fn inputDatagram(self: *Self, datagram: []const u8) !void {
            try self.inputPacket(datagram);
        }

        pub fn write(self: *Self, payload: []const u8) !usize {
            const written = try self.tx_bytes.writeBlocking(payload);
            self.wake();
            return written;
        }

        pub fn writeTimeout(self: *Self, payload: []const u8, timeout: glib.time.duration.Duration) !usize {
            const written = try self.tx_bytes.writeTimeout(payload, timeout);
            self.wake();
            return written;
        }

        pub fn read(self: *Self, buf: []u8) !usize {
            const n = try self.rx_bytes.readBlocking(buf);
            if (n != 0) self.wake();
            return n;
        }

        pub fn readTimeout(self: *Self, buf: []u8, timeout: glib.time.duration.Duration) !usize {
            const n = try self.rx_bytes.readTimeout(buf, timeout);
            if (n != 0) self.wake();
            return n;
        }

        pub fn close(self: *Self) void {
            self.stop();
        }

        pub fn waitsnd(self: *const Self) usize {
            const mutable: *Self = @constCast(self);
            mutable.wake_mutex.lock();
            defer mutable.wake_mutex.unlock();
            return mutable.pending_segments;
        }

        pub fn snapshot(self: *const Self) Snapshot {
            const mutable: *Self = @constCast(self);
            mutable.wake_mutex.lock();
            defer mutable.wake_mutex.unlock();
            return mutable.cached_snapshot;
        }

        pub fn checkTaskError(self: *Self) !void {
            self.wake_mutex.lock();
            defer self.wake_mutex.unlock();
            if (self.task_err) |err| return err;
        }

        fn driveLoopTask(self: *Self) void {
            self.driveLoop() catch |err| {
                std.log.scoped(.kcp_mux).err("drive loop failed: {s}", .{@errorName(err)});
                self.wake_mutex.lock();
                self.task_err = err;
                self.wake_pending = true;
                self.wake_mutex.unlock();
                self.input_packets.close();
                self.tx_bytes.close();
                self.rx_bytes.close();
            };
        }

        fn driveLoop(self: *Self) !void {
            var packet_buf: [drive_packet_buf_capacity]u8 = undefined;
            var send_buf: [drive_send_buf_capacity]u8 = undefined;
            var recv_buf: [drive_recv_buf_capacity]u8 = undefined;
            var progress_rounds: usize = 0;

            var now_ms = self.nowMs();
            self.beginOutputBurst();
            kcp.update(self.inst, now_ms);
            self.updateCachedState();
            try self.checkOutput();

            while (!self.shouldStop()) {
                now_ms = self.nowMs();
                var made_progress = false;

                while (self.input_packets.tryPop(&packet_buf) catch |err| switch (err) {
                    error.Closed => null,
                    else => return err,
                }) |packet_len| {
                    const rc = kcp.input(self.inst, packet_buf[0..packet_len].ptr, packet_len);
                    if (rc < 0) {
                        self.input_errors_total +%= 1;
                        made_progress = true;
                        continue;
                    }
                    self.input_packets_total +%= 1;
                    made_progress = true;
                }

                while (self.sendAdmissionBytes() > 0) {
                    const n = self.tx_bytes.tryRead(send_buf[0..@min(send_buf.len, self.sendAdmissionBytes())]) catch |err| switch (err) {
                        error.Closed => 0,
                        else => return err,
                    };
                    if (n == 0) break;
                    if (n > std.math.maxInt(c_int)) return error.KcpMuxPayloadTooLarge;
                    const rc = kcp.send(self.inst, send_buf[0..n].ptr, @intCast(n));
                    if (rc < 0) return error.KcpMuxSendFailed;
                    made_progress = true;
                }

                const due = kcp.check(self.inst, now_ms) <= now_ms;
                if (made_progress or due) {
                    self.beginOutputBurst();
                    if (due) {
                        kcp.update(self.inst, now_ms);
                    } else {
                        kcp.flush(self.inst);
                    }
                    try self.checkOutput();
                    made_progress = true;
                }

                while (true) {
                    const peek = kcp.peeksize(self.inst);
                    if (peek <= 0) break;
                    const recv_len = @min(@as(usize, @intCast(peek)), recv_buf.len);
                    if (self.rx_bytes.availableWrite() < recv_len) break;
                    const rc = kcp.recv(self.inst, recv_buf[0..recv_len].ptr, @intCast(recv_len));
                    if (rc < 0) break;
                    const received: usize = @intCast(rc);
                    if (received == 0) break;
                    const admitted = self.rx_bytes.tryWrite(recv_buf[0..received]) catch |err| switch (err) {
                        error.Closed => return,
                        else => return err,
                    };
                    if (admitted != received) return error.KcpMuxReceiveRingShortWrite;
                    made_progress = true;
                }
                self.updateCachedState();

                if (!made_progress) {
                    progress_rounds = 0;
                    self.waitForWake(now_ms);
                } else {
                    progress_rounds += 1;
                    if (progress_rounds >= cooperative_sleep_interval) {
                        progress_rounds = 0;
                        grt.time.sleep(cooperative_sleep_duration);
                    }
                }
            }
        }

        fn waitForWake(self: *Self, now_ms: u32) void {
            const check_ms = kcp.check(self.inst, now_ms);
            const timeout_ns: u64 = if (check_ms <= now_ms)
                0
            else
                @as(u64, check_ms - now_ms) * @as(u64, @intCast(glib.time.duration.MilliSecond));

            self.wake_mutex.lock();
            defer self.wake_mutex.unlock();
            if (self.stopping) return;
            if (timeout_ns == 0) return;
            if (self.wake_pending) {
                self.wake_pending = false;
                return;
            }
            self.wake_cond.timedWait(&self.wake_mutex, timeout_ns) catch {};
            self.wake_pending = false;
        }

        fn wake(self: *Self) void {
            self.wake_mutex.lock();
            defer self.wake_mutex.unlock();
            self.wake_pending = true;
            self.wake_cond.signal();
        }

        fn updateCachedState(self: *Self) void {
            const pending = kcp.waitsnd(self.inst);
            const pool = self.segment_pool.snapshot();
            const snap = Snapshot{
                .waitsnd = if (pending <= 0) 0 else @intCast(pending),
                .tx_bytes = self.tx_bytes.availableRead(),
                .tx_room = self.tx_bytes.availableWrite(),
                .rx_bytes = self.rx_bytes.availableRead(),
                .rx_room = self.rx_bytes.availableWrite(),
                .input_queue = self.input_packets.availableRead(),
                .input_room = self.input_packets.availableWrite(),
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
            self.wake_mutex.lock();
            self.pending_segments = snap.waitsnd;
            self.cached_snapshot = snap;
            self.wake_mutex.unlock();
        }

        fn sendAdmissionBytes(self: *Self) usize {
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
        }

        fn shouldStop(self: *Self) bool {
            self.wake_mutex.lock();
            defer self.wake_mutex.unlock();
            return self.stopping;
        }

        fn nowMs(self: *Self) u32 {
            const elapsed = grt.time.instant.sub(grt.time.instant.now(), self.start_at);
            if (elapsed <= 0) return 0;
            const elapsed_ms = @as(u64, @intCast(@divTrunc(elapsed, glib.time.duration.MilliSecond)));
            return @intCast(@min(elapsed_ms, std.math.maxInt(u32)));
        }

        fn checkOutput(self: *Self) !void {
            if (self.output_err) |err| {
                self.output_err = null;
                return err;
            }
        }

        const OutputContext = struct {
            mux: *Self,

            fn output(raw: [*c]const u8, len: c_int, _: [*c]kcp.Kcp, user: ?*anyopaque) callconv(.c) c_int {
                if (len < 0) return -1;
                const ctx: *OutputContext = @ptrCast(@alignCast(user orelse return -1));
                const self = ctx.mux;
                const datagram = raw[0..@intCast(len)];
                self.output_packets_total +%= 1;
                self.output_bytes_total +%= datagram.len;
                self.current_output_burst +%= 1;
                self.last_output_burst = self.current_output_burst;
                self.max_output_burst = @max(self.max_output_burst, self.current_output_burst);
                self.bearer.write(datagram) catch |err| {
                    self.output_drops_total +%= 1;
                    std.log.scoped(.kcp_mux).err("output failed: {s} len={d}", .{ @errorName(err), datagram.len });
                    self.output_err = err;
                    return -1;
                };
                return len;
            }
        };
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    return glib.testing.TestRunner.fromFn(grt.std, 512 * 1024, struct {
        fn run(_: *glib.testing.T, allocator: grt.std.mem.Allocator) !void {
            const std = grt.std;
            const Mux = make(grt);

            const Wire = struct {
                mutex: grt.sync.Mutex = .{},
                peer: ?*Mux = null,

                fn output(ctx: ?*anyopaque, datagram: []const u8) !void {
                    const self: *@This() = @ptrCast(@alignCast(ctx orelse return error.MissingWireContext));
                    self.mutex.lock();
                    const peer = self.peer;
                    self.mutex.unlock();
                    try (peer orelse return error.MissingPeer).inputPacket(datagram);
                }

                fn setPeer(self: *@This(), peer: *Mux) void {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    self.peer = peer;
                }
            };

            var a_to_b = Wire{};
            var b_to_a = Wire{};
            var a: Mux = undefined;
            try a.init(allocator, 7, .{ .mode = .stream }, .{ .ctx = &a_to_b, .writePacket = Wire.output });
            defer a.deinit();
            var b: Mux = undefined;
            try b.init(allocator, 7, .{ .mode = .stream }, .{ .ctx = &b_to_a, .writePacket = Wire.output });
            defer b.deinit();
            a_to_b.setPeer(&b);
            b_to_a.setPeer(&a);

            try a.startDefault();
            try b.startDefault();

            try std.testing.expectEqual(@as(usize, 5), try a.write("hello"));
            var out: [16]u8 = undefined;
            const n = try b.readTimeout(&out, 2 * glib.time.duration.Second);
            try std.testing.expectEqual(@as(usize, 5), n);
            try std.testing.expectEqualStrings("hello", out[0..5]);
        }
    }.run);
}
