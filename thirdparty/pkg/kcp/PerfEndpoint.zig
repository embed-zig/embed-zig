const glib = @import("glib");
const kcp = @import("../kcp.zig");
const Protocol = @import("PerfProtocol.zig");

const PerfEndpoint = @This();

pub const Mode = enum {
    packet,
    stream,
};

pub const Role = enum {
    client,
    server,
};

const transfer_timeout = 180 * glib.time.duration.Second;
const io_timeout = 100 * glib.time.duration.MilliSecond;
const diag_interval = 1 * glib.time.duration.Second;
const transfer_buf_size: usize = 8192;
const ping_payload_size: usize = 8;
const cooperative_sleep_interval: usize = 32;
const cooperative_sleep_duration = 1 * glib.time.duration.MilliSecond;
const session_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };
const reader_task_options: glib.task.Options = .{ .min_stack_size = 64 * 1024 };
const user_send_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };
const user_recv_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };

pub fn make(comptime grt: type) type {
    const std = grt.std;
    const Conn = grt.net.Conn;
    const PacketConn = grt.net.PacketConn;
    const AddrPort = glib.net.netip.AddrPort;
    const Session = kcp.Session.make(grt);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        pc: PacketConn,
        remote: AddrPort,
        session: Session,
        reader_handle: ?grt.task.Handle = null,
        state_mutex: grt.sync.Mutex = .{},
        stopping: bool = false,
        reader_err: ?anyerror = null,
        diag_control: ?Conn = null,
        diag_control_failed: bool = false,

        pub fn init(
            self: *Self,
            allocator: std.mem.Allocator,
            pc: PacketConn,
            remote: AddrPort,
            conv: u32,
            request: Protocol.Request,
            mode: Mode,
        ) !void {
            self.* = .{
                .allocator = allocator,
                .pc = pc,
                .remote = remote,
                .session = undefined,
            };
            const config = kcp.Session.Config{
                .mtu = request.udpPayload(),
                .mode = switch (mode) {
                    .packet => .packet,
                    .stream => .stream,
                },
                .nodelay = request.kcp.nodelay,
                .interval_ms = request.kcp.interval_ms,
                .resend = request.kcp.resend,
                .no_congestion_control = request.kcp.no_congestion_control,
                .send_window = request.kcp.send_window,
                .recv_window = request.kcp.recv_window,
            };
            try self.session.init(allocator, conv, config, .{ .ctx = self, .writePacket = writePacket });
            errdefer self.session.deinit();
            try self.session.start(session_task_options);
            errdefer self.session.stop();
            self.reader_handle = try grt.task.go("kcp/session/read", reader_task_options, glib.task.Routine.init(self, readerTask));
        }

        pub fn deinit(self: *Self) void {
            self.requestReaderStop();
            self.session.close();
            self.joinReader();
            self.session.deinit();
            self.pc.deinit();
            self.* = undefined;
        }

        pub fn setDiagControl(self: *Self, control: Conn) void {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            self.diag_control = control;
            self.diag_control_failed = false;
        }

        pub fn run(self: *Self, role: Role, request: Protocol.Request, ping_started: ?glib.time.instant.Time) !Protocol.Result {
            return switch (request.direction) {
                .down => switch (role) {
                    .client => try self.runTransfer(role, 0, request.bytes, request),
                    .server => try self.runTransfer(role, request.bytes, 0, request),
                },
                .up => switch (role) {
                    .client => try self.runTransfer(role, request.bytes, 0, request),
                    .server => try self.runTransfer(role, 0, request.bytes, request),
                },
                .duplex => try self.runTransfer(role, request.bytes, request.bytes, request),
                .ping => switch (role) {
                    .client => try self.runPingClient(ping_started orelse grt.time.instant.now()),
                    .server => try self.runPingServer(),
                },
            };
        }

        fn runTransfer(self: *Self, role: Role, send_total: usize, recv_total: usize, request: Protocol.Request) !Protocol.Result {
            var send_result = ThreadResult{};
            var recv_result = ThreadResult{};
            var send_task = UserSendTask{
                .endpoint = self,
                .bytes = send_total,
                .request = request,
                .out = &send_result,
            };
            var recv_task = UserRecvTask{
                .endpoint = self,
                .bytes = recv_total,
                .out = &recv_result,
            };

            const started = grt.time.instant.now();
            if (send_total == 0) send_result.finish(.{});
            if (recv_total == 0) recv_result.finish(.{});
            var send_handle: ?grt.task.Handle = null;
            var recv_handle: ?grt.task.Handle = null;
            defer {
                if (send_handle) |handle| handle.join();
                if (recv_handle) |handle| handle.join();
            }
            errdefer self.session.close();
            if (send_total != 0) {
                send_handle = try grt.task.go("kcp/session/user-send", user_send_task_options, glib.task.Routine.init(&send_task, UserSendTask.run));
            }
            if (recv_total != 0) {
                recv_handle = try grt.task.go("kcp/session/user-recv", user_recv_task_options, glib.task.Routine.init(&recv_task, UserRecvTask.run));
            }

            var next_diag_at: u64 = diag_interval;

            while (true) {
                try self.checkReaderError();
                try self.session.checkTaskError();
                const elapsed = elapsedSince(started);
                const send_snapshot = send_result.snapshot();
                const recv_snapshot = recv_result.snapshot();
                if (elapsed > transfer_timeout) {
                    self.logDiag("timeout", role, request, send_snapshot.result.sent_bytes, send_total, recv_snapshot.result.received_bytes, recv_total, started);
                    return error.NetperfTransferTimeout;
                }
                if (elapsed >= next_diag_at) {
                    self.logDiag("progress", role, request, send_snapshot.result.sent_bytes, send_total, recv_snapshot.result.received_bytes, recv_total, started);
                    next_diag_at = elapsed + diag_interval;
                }
                if (send_snapshot.done and recv_snapshot.done) {
                    break;
                }
                grt.time.sleep(cooperative_sleep_duration);
            }

            const final_send = send_result.snapshot();
            const final_recv = recv_result.snapshot();
            if (final_send.err) |err| return err;
            if (final_recv.err) |err| return err;

            const result = Protocol.Result{
                .sent_bytes = final_send.result.sent_bytes,
                .received_bytes = final_recv.result.received_bytes,
                .elapsed_ns = @max(final_send.result.elapsed_ns, final_recv.result.elapsed_ns),
                .errors = final_send.result.errors + final_recv.result.errors,
                .packets = final_send.result.packets + final_recv.result.packets,
            };
            self.logDiag("done", role, request, result.sent_bytes, send_total, result.received_bytes, recv_total, started);
            return result;
        }

        fn runPingClient(self: *Self, started: glib.time.instant.Time) !Protocol.Result {
            var payload: [ping_payload_size]u8 = undefined;
            var echo: [ping_payload_size + 1]u8 = undefined;
            fillPattern(&payload);

            const written = try self.session.writeTimeout(&payload, io_timeout);
            if (written != payload.len) return error.ShortWrite;
            const rtt_started = grt.time.instant.now();
            try self.readExactSession(&echo, transfer_timeout);
            const first_byte_ns = elapsedSince(started);
            if (echo[0] != 0xaa or !std.mem.eql(u8, &payload, echo[1..])) return error.InvalidPingEcho;
            return .{
                .sent_bytes = payload.len,
                .received_bytes = echo.len,
                .elapsed_ns = elapsedSince(started),
                .packets = 2,
                .first_byte_ns = first_byte_ns,
                .rtt_ns = elapsedSince(rtt_started),
            };
        }

        fn runPingServer(self: *Self) !Protocol.Result {
            var payload: [ping_payload_size]u8 = undefined;
            const started = grt.time.instant.now();
            try self.readExactSession(&payload, transfer_timeout);
            var echo: [ping_payload_size + 1]u8 = undefined;
            echo[0] = 0xaa;
            @memcpy(echo[1..], &payload);
            const written = try self.session.writeTimeout(&echo, io_timeout);
            if (written != echo.len) return error.ShortWrite;
            while (self.session.waitsnd() != 0) {
                if (elapsedSince(started) > transfer_timeout) return error.NetperfTransferTimeout;
                grt.time.sleep(1 * glib.time.duration.MilliSecond);
            }
            return .{
                .sent_bytes = echo.len,
                .received_bytes = payload.len,
                .elapsed_ns = elapsedSince(started),
                .packets = 2,
            };
        }

        fn readExactSession(self: *Self, out: []u8, timeout: glib.time.duration.Duration) !void {
            const deadline = glib.time.instant.add(grt.time.instant.now(), timeout);
            var offset: usize = 0;
            while (offset < out.len) {
                const remaining = glib.time.instant.sub(deadline, grt.time.instant.now());
                if (remaining <= 0) return error.Timeout;
                const n = try self.session.readTimeout(out[offset..], @intCast(remaining));
                if (n == 0) return error.EndOfStream;
                offset += n;
            }
        }

        const ThreadResult = struct {
            mutex: grt.sync.Mutex = .{},
            result: Protocol.Result = .{},
            err: ?anyerror = null,
            done: bool = false,

            const Snapshot = struct {
                result: Protocol.Result,
                err: ?anyerror,
                done: bool,
            };

            fn finish(self: *@This(), result: Protocol.Result) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.result = result;
                self.done = true;
            }

            fn fail(self: *@This(), err: anyerror) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.err = err;
                self.done = true;
            }

            fn snapshot(self: *@This()) Snapshot {
                self.mutex.lock();
                defer self.mutex.unlock();
                return .{
                    .result = self.result,
                    .err = self.err,
                    .done = self.done,
                };
            }

            fn update(self: *@This(), result: Protocol.Result) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.result = result;
            }
        };

        const UserSendTask = struct {
            endpoint: *Self,
            bytes: usize,
            request: Protocol.Request,
            out: *ThreadResult,

            fn run(self: *@This()) void {
                const result = self.endpoint.runUserSend(self.bytes, self.request, self.out) catch |err| {
                    self.out.fail(err);
                    return;
                };
                self.out.finish(result);
            }
        };

        const UserRecvTask = struct {
            endpoint: *Self,
            bytes: usize,
            out: *ThreadResult,

            fn run(self: *@This()) void {
                const result = self.endpoint.runUserRecv(self.bytes, self.out) catch |err| {
                    self.out.fail(err);
                    return;
                };
                self.out.finish(result);
            }
        };

        fn runUserSend(self: *Self, bytes: usize, request: Protocol.Request, out: *ThreadResult) !Protocol.Result {
            var send_buf: [transfer_buf_size]u8 = undefined;
            fillPattern(&send_buf);

            const started = grt.time.instant.now();
            var result = Protocol.Result{};
            while (result.sent_bytes < bytes) {
                try self.checkReaderError();
                try self.session.checkTaskError();
                if (elapsedSince(started) > transfer_timeout) return error.NetperfTransferTimeout;
                const chunk = @min(@min(request.streamChunk(), send_buf.len), bytes - result.sent_bytes);
                const written = self.session.writeTimeout(send_buf[0..chunk], io_timeout) catch |err| switch (err) {
                    error.Timeout => 0,
                    else => return err,
                };
                if (written == 0) {
                    grt.time.sleep(cooperative_sleep_duration);
                    continue;
                }
                result.sent_bytes += written;
                result.packets +%= 1;
                result.elapsed_ns = elapsedSince(started);
                out.update(result);
            }
            while (self.session.waitsnd() != 0) {
                try self.checkReaderError();
                try self.session.checkTaskError();
                if (elapsedSince(started) > transfer_timeout) return error.NetperfTransferTimeout;
                grt.time.sleep(cooperative_sleep_duration);
            }
            result.elapsed_ns = elapsedSince(started);
            return result;
        }

        fn runUserRecv(self: *Self, bytes: usize, out: *ThreadResult) !Protocol.Result {
            var recv_buf: [transfer_buf_size]u8 = undefined;
            const started = grt.time.instant.now();
            var result = Protocol.Result{};
            while (result.received_bytes < bytes) {
                try self.checkReaderError();
                try self.session.checkTaskError();
                if (elapsedSince(started) > transfer_timeout) return error.NetperfTransferTimeout;
                const want = @min(recv_buf.len, bytes - result.received_bytes);
                const n = self.session.readTimeout(recv_buf[0..want], io_timeout) catch |err| switch (err) {
                    error.Timeout,
                    error.Closed,
                    => 0,
                    else => return err,
                };
                if (n == 0) {
                    grt.time.sleep(cooperative_sleep_duration);
                    continue;
                }
                result.received_bytes += n;
                result.packets +%= 1;
                result.elapsed_ns = elapsedSince(started);
                out.update(result);
            }
            result.elapsed_ns = elapsedSince(started);
            return result;
        }

        fn readerTask(self: *Self) void {
            self.readerLoop() catch |err| {
                std.log.scoped(.kcp_perf_endpoint).err("reader failed: {s}", .{@errorName(err)});
                self.state_mutex.lock();
                self.reader_err = err;
                self.state_mutex.unlock();
                self.session.close();
            };
        }

        fn readerLoop(self: *Self) !void {
            var packet: [2048]u8 = undefined;
            while (!self.shouldStopReader()) {
                const result = self.pc.readFrom(&packet) catch |err| switch (err) {
                    error.Closed => return,
                    error.TimedOut => {
                        if (self.shouldStopReader()) return;
                        continue;
                    },
                    else => return err,
                };
                if (!addrEquals(result.addr, self.remote)) continue;
                if (result.bytes_read < kcp.OVERHEAD) continue;
                try self.session.inputPacket(packet[0..result.bytes_read]);
            }
        }

        fn requestReaderStop(self: *Self) void {
            self.state_mutex.lock();
            self.stopping = true;
            self.state_mutex.unlock();
            self.pc.setReadDeadline(grt.time.instant.now());
        }

        fn joinReader(self: *Self) void {
            if (self.reader_handle) |handle| handle.join();
            self.reader_handle = null;
        }

        fn shouldStopReader(self: *Self) bool {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            return self.stopping;
        }

        fn checkReaderError(self: *Self) !void {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            if (self.reader_err) |err| return err;
        }

        const PacketWriteSnapshot = struct {
            count: u64 = 0,
            avg_us: u64 = 0,
            max_us: u64 = 0,
        };

        const UdpRuntimeSnapshot = struct {
            retry_total: u64 = 0,
            retry_packets: u64 = 0,
            retry_max_per_packet: u64 = 0,
            enqueue_wait_total: u64 = 0,
            enqueue_wait_packets: u64 = 0,
            enqueue_wait_max_per_packet: u64 = 0,
        };

        fn writePacket(ctx: ?*anyopaque, datagram: []const u8) !void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return error.MissingPerfEndpoint));
            const written = self.pc.writeTo(datagram, self.remote) catch |err| {
                std.log.scoped(.kcp_perf_endpoint).err("write packet failed: {s} len={d}", .{ @errorName(err), datagram.len });
                return err;
            };
            if (written != datagram.len) return error.ShortWrite;
        }

        fn packetWriteSnapshot(_: *Self) PacketWriteSnapshot {
            return .{};
        }

        fn udpRuntimeSnapshot(self: *Self) UdpRuntimeSnapshot {
            const udp = self.pc.as(grt.net.UdpConn) catch return .{};
            const stats = udp.debugStats();
            const Stats = @TypeOf(stats);
            if (!@hasField(Stats, "send_retry_total")) return .{};
            return .{
                .retry_total = @intCast(stats.send_retry_total),
                .retry_packets = @intCast(stats.send_retry_packet_total),
                .retry_max_per_packet = @intCast(stats.send_retry_max_per_packet),
                .enqueue_wait_total = @intCast(stats.send_enqueue_wait_total),
                .enqueue_wait_packets = @intCast(stats.send_enqueue_wait_packet_total),
                .enqueue_wait_max_per_packet = @intCast(stats.send_enqueue_wait_max_per_packet),
            };
        }

        fn addrEquals(a: AddrPort, b: AddrPort) bool {
            return std.meta.eql(a, b);
        }

        fn fillPattern(buf: []u8) void {
            for (buf, 0..) |*b, i| b.* = @intCast(i % 251);
        }

        fn elapsedSince(started: glib.time.instant.Time) u64 {
            const elapsed = grt.time.instant.since(started);
            if (elapsed <= 0) return 0;
            return @intCast(elapsed);
        }

        fn logDiag(
            self: *Self,
            label: []const u8,
            role: Role,
            request: Protocol.Request,
            sent: usize,
            send_total: usize,
            received: usize,
            recv_total: usize,
            started: glib.time.instant.Time,
        ) void {
            const snap = self.session.snapshot();
            const packet_write = self.packetWriteSnapshot();
            const udp_runtime = self.udpRuntimeSnapshot();
            const elapsed_ms = elapsedSince(started) / @as(u64, @intCast(glib.time.duration.MilliSecond));
            const log = std.log.scoped(.kcp_perf_endpoint);
            log.info(
                "{s} role={s} proto={s} dir={s} ms={d} s={d}/{d} r={d}/{d} wait={d} tx={d}/{d} rx={d}/{d} iq={d}/{d}",
                .{
                    label,
                    @tagName(role),
                    request.protocol.name(),
                    @tagName(request.direction),
                    elapsed_ms,
                    sent,
                    send_total,
                    received,
                    recv_total,
                    snap.waitsnd,
                    snap.tx_bytes,
                    snap.tx_room,
                    snap.rx_bytes,
                    snap.rx_room,
                    snap.input_queue,
                    snap.input_room,
                },
            );
            log.info(
                "{s} role={s} proto={s} dir={s} ms={d} sq={d} sb={d} rq={d} rb={d} rw={d} cw={d} rto={d} srtt={d} rv={d} xmit={d} out={d}/{d} drop={d} in={d} ierr={d}",
                .{
                    label,
                    @tagName(role),
                    request.protocol.name(),
                    @tagName(request.direction),
                    elapsed_ms,
                    snap.snd_queue,
                    snap.snd_buf,
                    snap.rcv_queue,
                    snap.rcv_buf,
                    snap.rmt_wnd,
                    snap.cwnd,
                    snap.rx_rto,
                    snap.rx_srtt,
                    snap.rx_rttval,
                    snap.xmit,
                    snap.output_packets,
                    snap.output_bytes,
                    snap.output_drops,
                    snap.input_packets,
                    snap.input_errors,
                },
            );
            log.info(
                "{s} role={s} proto={s} dir={s} ms={d} ob={d}/{d} outseg new={d} fast={d} rt={d} ack={d} wask={d} wins={d} inseg ack={d} push={d} pool={d}/{d} pa={d} pf={d} fa={d} ff={d} fail={d}",
                .{
                    label,
                    @tagName(role),
                    request.protocol.name(),
                    @tagName(request.direction),
                    elapsed_ms,
                    snap.last_output_burst,
                    snap.max_output_burst,
                    snap.output_new_segments,
                    snap.output_fast_segments,
                    snap.output_rto_segments,
                    snap.output_ack_segments,
                    snap.output_wask_segments,
                    snap.output_wins_segments,
                    snap.input_ack_segments,
                    snap.input_push_segments,
                    snap.pool_available_segments,
                    snap.pool_reserved_segments,
                    snap.pool_pooled_allocs,
                    snap.pool_pooled_frees,
                    snap.pool_fallback_allocs,
                    snap.pool_fallback_frees,
                    snap.pool_allocation_failures,
                },
            );
            log.info(
                "{s} role={s} proto={s} dir={s} ms={d} loop={d} sleep={d}/{d}ms zero={d} work={d}/{d}us late={d}us lock={d}/{d}us upd={d}/{d}us upd_ob={d} upd_cb={d}/{d}us upd_write={d}/{d}us upd_core={d}us post={d}/{d}us",
                .{
                    label,
                    @tagName(role),
                    request.protocol.name(),
                    @tagName(request.direction),
                    elapsed_ms,
                    snap.loop_count,
                    snap.loop_sleep_count,
                    snap.loop_sleep_ms,
                    snap.loop_zero_sleep_count,
                    snap.loop_work_us,
                    snap.loop_work_max_us,
                    snap.loop_late_max_us,
                    snap.loop_lock_wait_us,
                    snap.loop_lock_wait_max_us,
                    snap.loop_update_us,
                    snap.loop_update_max_us,
                    snap.loop_update_max_output_burst,
                    snap.loop_update_max_output_callback_us,
                    snap.loop_update_max_output_callback_max_us,
                    snap.loop_update_max_output_write_us,
                    snap.loop_update_max_output_write_max_us,
                    snap.loop_update_max_internal_us,
                    snap.loop_post_us,
                    snap.loop_post_max_us,
                },
            );
            log.info(
                "{s} role={s} proto={s} dir={s} ms={d} udpw={d} avg={d}us max={d}us retry={d}/{d} retryMax={d} qwait={d}/{d} qwaitMax={d}",
                .{
                    label,
                    @tagName(role),
                    request.protocol.name(),
                    @tagName(request.direction),
                    elapsed_ms,
                    packet_write.count,
                    packet_write.avg_us,
                    packet_write.max_us,
                    udp_runtime.retry_total,
                    udp_runtime.retry_packets,
                    udp_runtime.retry_max_per_packet,
                    udp_runtime.enqueue_wait_total,
                    udp_runtime.enqueue_wait_packets,
                    udp_runtime.enqueue_wait_max_per_packet,
                },
            );
            self.writeDiagControl(label, role, request, sent, received, elapsed_ms, snap, packet_write, udp_runtime);
        }

        fn writeDiagControl(
            self: *Self,
            label: []const u8,
            role: Role,
            request: Protocol.Request,
            sent: usize,
            received: usize,
            elapsed_ms: u64,
            snap: Session.Snapshot,
            packet_write: PacketWriteSnapshot,
            udp_runtime: UdpRuntimeSnapshot,
        ) void {
            var line_buf: [Protocol.max_line_len]u8 = undefined;
            var timing_line_buf: [Protocol.max_line_len]u8 = undefined;
            var udp_line_buf: [Protocol.max_line_len]u8 = undefined;
            const line = std.fmt.bufPrint(
                &line_buf,
                "{s} DIAG session {s} role={s} proto={s} dir={s} ms={d} s={d} r={d} w={d} sq={d} sb={d} rq={d} rb={d} rw={d} cw={d} rto={d} xmit={d} out={d} drop={d} in={d}\n",
                .{
                    Protocol.magic,
                    label,
                    @tagName(role),
                    request.protocol.name(),
                    @tagName(request.direction),
                    elapsed_ms,
                    sent,
                    received,
                    snap.waitsnd,
                    snap.snd_queue,
                    snap.snd_buf,
                    snap.rcv_queue,
                    snap.rcv_buf,
                    snap.rmt_wnd,
                    snap.cwnd,
                    snap.rx_rto,
                    snap.xmit,
                    snap.output_packets,
                    snap.output_drops,
                    snap.input_packets,
                },
            ) catch return;
            const timing_line = std.fmt.bufPrint(
                &timing_line_buf,
                "{s} DIAG timing {s} role={s} proto={s} dir={s} ms={d} loop={d} sleep={d}/{d} zero={d} work={d}/{d} late={d} lock={d}/{d} upd={d}/{d} upd_ob={d} upd_cb={d}/{d} upd_write={d}/{d} upd_core={d} post={d}/{d} ob={d}/{d}\n",
                .{
                    Protocol.magic,
                    label,
                    @tagName(role),
                    request.protocol.name(),
                    @tagName(request.direction),
                    elapsed_ms,
                    snap.loop_count,
                    snap.loop_sleep_count,
                    snap.loop_sleep_ms,
                    snap.loop_zero_sleep_count,
                    snap.loop_work_us,
                    snap.loop_work_max_us,
                    snap.loop_late_max_us,
                    snap.loop_lock_wait_us,
                    snap.loop_lock_wait_max_us,
                    snap.loop_update_us,
                    snap.loop_update_max_us,
                    snap.loop_update_max_output_burst,
                    snap.loop_update_max_output_callback_us,
                    snap.loop_update_max_output_callback_max_us,
                    snap.loop_update_max_output_write_us,
                    snap.loop_update_max_output_write_max_us,
                    snap.loop_update_max_internal_us,
                    snap.loop_post_us,
                    snap.loop_post_max_us,
                    snap.last_output_burst,
                    snap.max_output_burst,
                },
            ) catch return;
            const udp_line = std.fmt.bufPrint(
                &udp_line_buf,
                "{s} DIAG udp {s} role={s} proto={s} dir={s} ms={d} writes={d} avg_us={d} max_us={d} retry={d}/{d} retry_max={d} qwait={d}/{d} qwait_max={d}\n",
                .{
                    Protocol.magic,
                    label,
                    @tagName(role),
                    request.protocol.name(),
                    @tagName(request.direction),
                    elapsed_ms,
                    packet_write.count,
                    packet_write.avg_us,
                    packet_write.max_us,
                    udp_runtime.retry_total,
                    udp_runtime.retry_packets,
                    udp_runtime.retry_max_per_packet,
                    udp_runtime.enqueue_wait_total,
                    udp_runtime.enqueue_wait_packets,
                    udp_runtime.enqueue_wait_max_per_packet,
                },
            ) catch return;

            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            if (self.diag_control_failed) return;
            const conn = self.diag_control orelse return;
            writeAll(conn, line) catch {
                self.diag_control_failed = true;
            };
            writeAll(conn, timing_line) catch {
                self.diag_control_failed = true;
            };
            writeAll(conn, udp_line) catch {
                self.diag_control_failed = true;
            };
        }

        fn writeAll(conn: Conn, buf: []const u8) !void {
            var offset: usize = 0;
            while (offset < buf.len) {
                const n = try conn.write(buf[offset..]);
                if (n == 0) return error.ShortWrite;
                offset += n;
            }
        }
    };
}
