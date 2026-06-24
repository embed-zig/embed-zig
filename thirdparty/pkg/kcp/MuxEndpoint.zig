const glib = @import("glib");
const kcp = @import("../kcp.zig");
const Protocol = @import("PerfProtocol.zig");

const MuxEndpoint = @This();

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
const reader_timeout = 100 * glib.time.duration.MilliSecond;
const diag_interval = 1 * glib.time.duration.Second;
const transfer_buf_size: usize = 8192;
const ping_payload_size: usize = 8;
const cooperative_sleep_interval: usize = 32;
const cooperative_sleep_duration = 1 * glib.time.duration.MilliSecond;
const mux_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };
const reader_task_options: glib.task.Options = .{ .min_stack_size = 64 * 1024 };

pub fn make(comptime grt: type) type {
    const std = grt.std;
    const Conn = grt.net.Conn;
    const PacketConn = grt.net.PacketConn;
    const AddrPort = glib.net.netip.AddrPort;
    const Mux = kcp.Mux.make(grt);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        pc: PacketConn,
        remote: AddrPort,
        mux: Mux,
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
                .mux = undefined,
            };
            const config = kcp.Mux.Config{
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
            try self.mux.init(allocator, conv, config, .{ .ctx = self, .writePacket = writePacket });
            errdefer self.mux.deinit();
            try self.mux.start(mux_task_options);
            errdefer self.mux.stop();
            self.reader_handle = try grt.task.go("kcp/mux/read", reader_task_options, glib.task.Routine.init(self, readerTask));
        }

        pub fn deinit(self: *Self) void {
            self.requestReaderStop();
            self.mux.close();
            self.joinReader();
            self.mux.deinit();
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
            var send_buf: [transfer_buf_size]u8 = undefined;
            var recv_buf: [transfer_buf_size]u8 = undefined;
            fillPattern(&send_buf);

            const started = grt.time.instant.now();
            var sent: usize = 0;
            var received: usize = 0;
            var packets: u32 = 0;
            var progress_rounds: usize = 0;
            var next_diag_at: u64 = diag_interval;

            while (true) {
                try self.checkReaderError();
                try self.mux.checkTaskError();
                const elapsed = elapsedSince(started);
                if (elapsed > transfer_timeout) {
                    self.logDiag("timeout", role, request, sent, send_total, received, recv_total, started);
                    return error.NetperfTransferTimeout;
                }
                if (elapsed >= next_diag_at) {
                    self.logDiag("progress", role, request, sent, send_total, received, recv_total, started);
                    next_diag_at = elapsed + diag_interval;
                }

                var made_progress = false;
                if (sent < send_total) {
                    const chunk = @min(request.streamChunk(), send_total - sent);
                    const written = self.mux.writeTimeout(send_buf[0..chunk], io_timeout) catch |err| switch (err) {
                        error.Timeout => 0,
                        else => return err,
                    };
                    sent += written;
                    if (written != 0) {
                        packets +%= 1;
                        made_progress = true;
                    }
                }

                if (received < recv_total) {
                    const want = @min(recv_buf.len, recv_total - received);
                    const n = self.mux.readTimeout(recv_buf[0..want], io_timeout) catch |err| switch (err) {
                        error.Timeout => 0,
                        error.Closed => 0,
                        else => return err,
                    };
                    received += n;
                    if (n != 0) {
                        packets +%= 1;
                        made_progress = true;
                    }
                }

                if (sent >= send_total and received >= recv_total and self.mux.waitsnd() == 0) {
                    break;
                }

                if (!made_progress) {
                    progress_rounds = 0;
                    grt.time.sleep(cooperative_sleep_duration);
                } else {
                    progress_rounds += 1;
                    if (progress_rounds >= cooperative_sleep_interval) {
                        progress_rounds = 0;
                        grt.time.sleep(cooperative_sleep_duration);
                    }
                }
            }
            self.logDiag("done", role, request, sent, send_total, received, recv_total, started);

            return .{
                .sent_bytes = sent,
                .received_bytes = received,
                .elapsed_ns = elapsedSince(started),
                .packets = packets,
            };
        }

        fn runPingClient(self: *Self, started: glib.time.instant.Time) !Protocol.Result {
            var payload: [ping_payload_size]u8 = undefined;
            var echo: [ping_payload_size + 1]u8 = undefined;
            fillPattern(&payload);

            const written = try self.mux.writeTimeout(&payload, io_timeout);
            if (written != payload.len) return error.ShortWrite;
            const rtt_started = grt.time.instant.now();
            try self.readExactMux(&echo, transfer_timeout);
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
            try self.readExactMux(&payload, transfer_timeout);
            var echo: [ping_payload_size + 1]u8 = undefined;
            echo[0] = 0xaa;
            @memcpy(echo[1..], &payload);
            const written = try self.mux.writeTimeout(&echo, io_timeout);
            if (written != echo.len) return error.ShortWrite;
            while (self.mux.waitsnd() != 0) {
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

        fn readExactMux(self: *Self, out: []u8, timeout: glib.time.duration.Duration) !void {
            const deadline = glib.time.instant.add(grt.time.instant.now(), timeout);
            var offset: usize = 0;
            while (offset < out.len) {
                const remaining = glib.time.instant.sub(deadline, grt.time.instant.now());
                if (remaining <= 0) return error.Timeout;
                const n = try self.mux.readTimeout(out[offset..], @intCast(remaining));
                if (n == 0) return error.EndOfStream;
                offset += n;
            }
        }

        fn readerTask(self: *Self) void {
            self.readerLoop() catch |err| {
                std.log.scoped(.kcp_mux_endpoint).err("reader failed: {s}", .{@errorName(err)});
                self.state_mutex.lock();
                self.reader_err = err;
                self.state_mutex.unlock();
                self.mux.close();
            };
        }

        fn readerLoop(self: *Self) !void {
            var packet: [2048]u8 = undefined;
            defer self.pc.setReadDeadline(null);
            while (!self.shouldStopReader()) {
                self.pc.setReadDeadline(glib.time.instant.add(grt.time.instant.now(), reader_timeout));
                const result = self.pc.readFrom(&packet) catch |err| switch (err) {
                    error.TimedOut => continue,
                    error.Closed => return,
                    else => return err,
                };
                if (!addrEquals(result.addr, self.remote)) continue;
                if (result.bytes_read < kcp.OVERHEAD) continue;
                try self.mux.inputPacket(packet[0..result.bytes_read]);
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

        fn writePacket(ctx: ?*anyopaque, datagram: []const u8) !void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return error.MissingMuxEndpoint));
            const written = self.pc.writeTo(datagram, self.remote) catch |err| {
                std.log.scoped(.kcp_mux_endpoint).err("write packet failed: {s} len={d}", .{ @errorName(err), datagram.len });
                return err;
            };
            if (written != datagram.len) return error.ShortWrite;
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
            const snap = self.mux.snapshot();
            const elapsed_ms = elapsedSince(started) / @as(u64, @intCast(glib.time.duration.MilliSecond));
            const log = std.log.scoped(.kcp_mux_endpoint);
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
            self.writeDiagControl(label, role, request, sent, received, elapsed_ms, snap);
        }

        fn writeDiagControl(
            self: *Self,
            label: []const u8,
            role: Role,
            request: Protocol.Request,
            sent: usize,
            received: usize,
            elapsed_ms: u64,
            snap: Mux.Snapshot,
        ) void {
            var line_buf: [Protocol.max_line_len]u8 = undefined;
            const line = std.fmt.bufPrint(
                &line_buf,
                "{s} DIAG mux {s} role={s} proto={s} dir={s} ms={d} s={d} r={d} w={d} sq={d} sb={d} rq={d} rb={d} rw={d} cw={d} rto={d} xmit={d} out={d} drop={d} in={d} ob={d}/{d} oa={d} ia={d} ip={d}\n",
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
                    snap.last_output_burst,
                    snap.max_output_burst,
                    snap.output_ack_segments,
                    snap.input_ack_segments,
                    snap.input_push_segments,
                },
            ) catch return;

            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            if (self.diag_control_failed) return;
            const conn = self.diag_control orelse return;
            writeAll(conn, line) catch {
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
