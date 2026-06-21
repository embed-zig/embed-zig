const glib = @import("glib");
const Protocol = @import("PerfProtocol.zig");
const SessionFile = @import("Session.zig");

const AddrPort = glib.net.netip.AddrPort;
const transfer_timeout = 60 * glib.time.duration.Second;
const udp_idle_timeout = 2 * glib.time.duration.Second;
const kcp_write_timeout = 10 * glib.time.duration.Second;
const stream_write_buffer_size = 8192;
const stream_read_buffer_size = 1440;
const ping_payload_size = 8;
const kcp_progress_interval_bytes = 512 * 1024;
const default_udp_socket_buffer_size = 4 * 1024 * 1024;
const default_tcp_socket_buffer_size = 48 * 1600;
const kcp_read_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };
const kcp_drive_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };
const kcp_write_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };
const netperf_send_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };
const netperf_recv_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };

pub fn make(comptime grt: type) type {
    const std = grt.std;
    const Net = grt.net;
    const Conn = Net.Conn;
    const PacketConn = Net.PacketConn;
    const Session = SessionFile.make(grt);
    const AtomicBool = std.atomic.Value(bool);

    return struct {
        const Self = @This();

        pub const Config = struct {
            control_addr: AddrPort = AddrPort.from4(.{ 0, 0, 0, 0 }, Protocol.default_control_port),
            backlog: u31 = 8,
            idle_timeout: glib.time.duration.Duration = 5 * glib.time.duration.Second,
            udp_socket_buffer_size: usize = default_udp_socket_buffer_size,
            tcp_socket_buffer_size: usize = default_tcp_socket_buffer_size,
        };

        allocator: std.mem.Allocator,
        config: Config,

        pub fn init(allocator: std.mem.Allocator, config: Config) Self {
            return .{
                .allocator = allocator,
                .config = config,
            };
        }

        pub fn serve(self: *Self) !void {
            const log = std.log.scoped(.netperf_server);
            if (@hasDecl(Net.Runtime, "init")) {
                try Net.Runtime.init();
            }

            var listener = try Net.listen(self.allocator, .{
                .address = self.config.control_addr,
                .backlog = self.config.backlog,
            });
            defer listener.deinit();

            while (true) {
                var control = try listener.accept();
                const result = self.handle(control) catch |err| {
                    control.deinit();
                    log.err("session failed: {s}", .{@errorName(err)});
                    continue;
                };
                control.deinit();
                log.info(
                    "result sent={d} recv={d} elapsed_ns={d} mbps={d:.3} packets={d} errors={d} first_byte_ns={d} rtt_ns={d}",
                    .{
                        result.sent_bytes,
                        result.received_bytes,
                        result.elapsed_ns,
                        result.mbps(),
                        result.packets,
                        result.errors,
                        result.first_byte_ns,
                        result.rtt_ns,
                    },
                );
            }
        }

        pub fn serveOnce(self: *Self) !Protocol.Result {
            if (@hasDecl(Net.Runtime, "init")) {
                try Net.Runtime.init();
            }

            var listener = try Net.listen(self.allocator, .{
                .address = self.config.control_addr,
                .backlog = self.config.backlog,
            });
            defer listener.deinit();

            var control = try listener.accept();
            defer control.deinit();
            return self.handle(control);
        }

        pub fn handle(self: *Self, control: Conn) !Protocol.Result {
            var line_buf: [Protocol.max_line_len]u8 = undefined;
            const request_line = try readLine(control, &line_buf);
            const request = try Protocol.parseRequest(std, request_line);

            return switch (request.protocol) {
                .tcp => try self.runTcp(control, request),
                .udp => try self.runUdp(control, request),
                .kcp => try self.runKcp(control, request),
            };
        }

        fn runTcp(self: *Self, control: Conn, request: Protocol.Request) !Protocol.Result {
            var listener = try Net.listen(self.allocator, .{
                .address = dataBindAddr(self.config.control_addr),
                .backlog = 4,
            });
            defer listener.deinit();
            const tcp_port = try boundTcpPort(listener);
            waitForDataPortPublish();

            try configureTcpConn(control, request.nodelayEnabled(), self.config.tcp_socket_buffer_size);
            try writeReady(control, .{
                .tcp_port = tcp_port,
                .conv = request.conv,
            });

            var data = try listener.accept();
            defer data.deinit();
            try configureTcpConn(data, request.nodelayEnabled(), self.config.tcp_socket_buffer_size);

            const result = if (request.direction == .ping)
                try pingConnServer(data)
            else if (request.direction == .duplex) blk: {
                break :blk try duplexConn(data, request.bytes, request.streamChunk());
            } else try runConnTransfer(data, request);
            try finish(control, request, result);
            return result;
        }

        fn runUdp(self: *Self, control: Conn, request: Protocol.Request) !Protocol.Result {
            var pc = try Net.listenPacket(.{
                .allocator = self.allocator,
                .address = dataBindAddr(self.config.control_addr),
            });
            defer pc.deinit();
            try configurePacketConn(pc, self.config.udp_socket_buffer_size);
            const udp_port = try boundPacketPort(pc);
            waitForDataPortPublish();

            try writeReady(control, .{
                .udp_port = udp_port,
                .conv = request.conv,
            });

            const remote = try waitHello(pc, request.conv, self.config.idle_timeout);
            const result = try runPacketTransfer(self.allocator, pc, remote, request);
            try finish(control, request, result);
            return result;
        }

        fn runKcp(self: *Self, control: Conn, request: Protocol.Request) !Protocol.Result {
            var pc = try Net.listenPacket(.{
                .allocator = self.allocator,
                .address = dataBindAddr(self.config.control_addr),
            });
            defer pc.deinit();
            try configurePacketConn(pc, self.config.udp_socket_buffer_size);
            const udp_port = try boundPacketPort(pc);
            waitForDataPortPublish();

            try writeReady(control, .{
                .udp_port = udp_port,
                .conv = request.conv,
            });

            const remote = try waitHello(pc, request.conv, self.config.idle_timeout);
            var session: Session = undefined;
            try session.init(self.allocator, pc, remote, request.conv, sessionConfig(request));
            defer session.deinit();

            var stop = AtomicBool.init(false);
            var read_result = DriveResult{};
            var drive_result = DriveResult{};
            var write_result = DriveResult{};
            var read_task = ReadLoopTask{
                .session = &session,
                .stop = &stop,
                .out = &read_result,
            };
            var drive_task = DriveLoopTask{
                .session = &session,
                .stop = &stop,
                .out = &drive_result,
            };
            var write_task = WriteLoopTask{
                .session = &session,
                .stop = &stop,
                .out = &write_result,
            };
            const read_handle = try grt.task.go("kcp/read", kcp_read_task_options, glib.task.Routine.init(&read_task, ReadLoopTask.run));
            const drive_handle = try grt.task.go("kcp/drive", kcp_drive_task_options, glib.task.Routine.init(&drive_task, DriveLoopTask.run));
            const write_handle = try grt.task.go("kcp/write", kcp_write_task_options, glib.task.Routine.init(&write_task, WriteLoopTask.run));
            var drive_joined = false;
            defer if (!drive_joined) {
                stop.store(true, .release);
                _ = session.tick() catch {};
                write_handle.join();
                drive_handle.join();
                read_handle.join();
            };

            const result = try runKcpTransfer(&session, request);
            try finish(control, request, result);

            stop.store(true, .release);
            _ = session.tick() catch {};
            write_handle.join();
            drive_handle.join();
            read_handle.join();
            drive_joined = true;
            if (read_result.err) |err| return err;
            if (drive_result.err) |err| return err;
            if (write_result.err) |err| return err;
            return result;
        }

        fn waitForDataPortPublish() void {
            grt.time.sleep(100 * glib.time.duration.MilliSecond);
        }

        fn dataBindAddr(control_addr: AddrPort) AddrPort {
            const ip = control_addr.addr();
            if (ip.is4() or ip.is4In6()) return AddrPort.from4(.{ 0, 0, 0, 0 }, 0);
            return AddrPort.from16([_]u8{0} ** 16, 0);
        }

        fn boundPacketPort(pc: PacketConn) !u16 {
            const impl = try pc.as(Net.UdpConn);
            return try impl.boundPort();
        }

        fn boundTcpPort(listener: Net.Listener) !u16 {
            const impl = try listener.as(Net.TcpListener);
            return try impl.port();
        }

        fn configurePacketConn(pc: PacketConn, socket_buffer_size: usize) !void {
            const udp = try pc.as(Net.UdpConn);
            setUdpBuffer(udp, .read, socket_buffer_size) catch |err| switch (err) {
                error.Unsupported => {},
                else => return err,
            };
            setUdpBuffer(udp, .write, socket_buffer_size) catch |err| switch (err) {
                error.Unsupported => {},
                else => return err,
            };
        }

        fn setUdpBuffer(udp: *Net.UdpConn, direction: enum { read, write }, size: usize) !void {
            return switch (direction) {
                .read => udp.setReadBufferSize(size),
                .write => udp.setWriteBufferSize(size),
            };
        }

        fn configureTcpConn(conn: Conn, no_delay: bool, socket_buffer_size: usize) !void {
            const tcp = conn.as(Net.TcpConn) catch |err| switch (err) {
                error.TypeMismatch => return,
            };
            setTcpBuffer(tcp, .read, socket_buffer_size) catch |err| switch (err) {
                error.Unsupported => {},
                else => return err,
            };
            setTcpBuffer(tcp, .write, socket_buffer_size) catch |err| switch (err) {
                error.Unsupported => {},
                else => return err,
            };
            if (no_delay) {
                tcp.socket.setOpt(.{ .tcp = .{ .no_delay = true } }) catch |err| switch (err) {
                    error.Unsupported => {},
                    else => return err,
                };
            }
        }

        fn setTcpBuffer(tcp: *Net.TcpConn, direction: enum { read, write }, size: usize) !void {
            return switch (direction) {
                .read => tcp.setReadBufferSize(size),
                .write => tcp.setWriteBufferSize(size),
            };
        }

        fn runConnTransfer(conn: Conn, request: Protocol.Request) !Protocol.Result {
            return switch (request.direction) {
                .down => try sendConn(conn, request.bytes, request.streamChunk()),
                .up => try recvConn(conn, request.bytes),
                .duplex => try duplexConn(conn, request.bytes, request.streamChunk()),
                .ping => try pingConnServer(conn),
            };
        }

        fn runPacketTransfer(allocator: std.mem.Allocator, pc: PacketConn, remote: AddrPort, request: Protocol.Request) !Protocol.Result {
            return switch (request.direction) {
                .down => try sendPacket(allocator, pc, remote, request.bytes, request.udpPayload()),
                .up => try recvPacket(allocator, pc, request.bytes, request.udpPayload()),
                .duplex => try duplexPacket(allocator, pc, remote, request.bytes, request.udpPayload()),
                .ping => error.UnsupportedProtocolDirection,
            };
        }

        fn runKcpTransfer(session: *Session, request: Protocol.Request) !Protocol.Result {
            return switch (request.direction) {
                .down => try sendKcp(session, request.bytes, request.streamChunk()),
                .up => try recvKcp(session, request.bytes),
                .duplex => try duplexKcp(session, request.bytes, request.streamChunk()),
                .ping => try pingKcpServer(session),
            };
        }

        fn waitHello(pc: PacketConn, conv: u32, timeout: glib.time.duration.Duration) !AddrPort {
            var line_buf: [Protocol.max_line_len]u8 = undefined;
            pc.setReadDeadline(glib.time.instant.add(grt.time.instant.now(), timeout));
            defer pc.setReadDeadline(null);
            const result = try pc.readFrom(&line_buf);
            const line = Protocol.trimLine(std, line_buf[0..result.bytes_read]);
            var expected_buf: [64]u8 = undefined;
            const expected = try Protocol.helloLine(std, &expected_buf, conv);
            if (!std.mem.eql(u8, line, Protocol.trimLine(std, expected))) return error.InvalidHello;
            return result.addr;
        }

        fn writeReady(control: Conn, ready: Protocol.Ready) !void {
            var buf: [Protocol.max_line_len]u8 = undefined;
            try writeAll(control, try Protocol.readyLine(std, &buf, ready));
        }

        fn writeResult(control: Conn, role: []const u8, result: Protocol.Result) !void {
            var buf: [Protocol.max_line_len]u8 = undefined;
            try writeAll(control, try Protocol.resultLine(std, &buf, role, result));
        }

        fn finish(control: Conn, request: Protocol.Request, server_result: Protocol.Result) !void {
            var line_buf: [Protocol.max_line_len]u8 = undefined;
            const line = try readLine(control, &line_buf);
            const client_result = try Protocol.parseStop(std, line);
            const log = std.log.scoped(.netperf_server);
            log.info(
                "client_result sent={d} recv={d} elapsed_ns={d} mbps={d:.3} packets={d} errors={d} first_byte_ns={d} rtt_ns={d}",
                .{
                    client_result.sent_bytes,
                    client_result.received_bytes,
                    client_result.elapsed_ns,
                    client_result.mbps(),
                    client_result.packets,
                    client_result.errors,
                    client_result.first_byte_ns,
                    client_result.rtt_ns,
                },
            );
            if (request.protocol == .udp) {
                logUdpLoss(log, request, server_result, client_result);
            }
            try writeResult(control, "server", server_result);
        }

        fn sessionConfig(request: Protocol.Request) SessionFile.Config {
            return .{
                .send_window = request.kcp.send_window,
                .recv_window = request.kcp.recv_window,
                .nodelay = request.kcp.nodelay,
                .interval_ms = request.kcp.interval_ms,
                .resend = request.kcp.resend,
                .no_congestion_control = request.kcp.no_congestion_control,
                .stream = request.kcp.stream,
                .send_batch_bytes = 8192,
                .write_timeout = kcp_write_timeout,
                .output_write_timeout = kcp_write_timeout,
            };
        }

        fn sendConn(conn: Conn, bytes: usize, chunk: usize) !Protocol.Result {
            var buf: [stream_write_buffer_size]u8 = undefined;
            fillPattern(&buf);
            const started = grt.time.instant.now();
            conn.setWriteDeadline(glib.time.instant.add(started, transfer_timeout));
            defer conn.setWriteDeadline(null);
            var sent: usize = 0;
            var packets: u32 = 0;
            while (sent < bytes) {
                const n = @min(@min(chunk, buf.len), bytes - sent);
                writeAll(conn, buf[0..n]) catch |err| switch (err) {
                    error.TimedOut,
                    error.BrokenPipe,
                    error.ConnectionReset,
                    error.ConnectionRefused,
                    error.ShortWrite,
                    => return .{
                        .sent_bytes = sent,
                        .elapsed_ns = elapsedSince(started),
                        .errors = 1,
                        .packets = packets,
                    },
                    else => return err,
                };
                sent += n;
                packets +%= 1;
            }
            return .{
                .sent_bytes = sent,
                .elapsed_ns = elapsedSince(started),
                .packets = packets,
            };
        }

        fn recvConn(conn: Conn, bytes: usize) !Protocol.Result {
            var buf: [stream_read_buffer_size]u8 = undefined;
            const started = grt.time.instant.now();
            conn.setReadDeadline(glib.time.instant.add(started, transfer_timeout));
            defer conn.setReadDeadline(null);
            var received: usize = 0;
            var packets: u32 = 0;
            while (received < bytes) {
                if (elapsedSince(started) > transfer_timeout) return .{
                    .received_bytes = received,
                    .elapsed_ns = elapsedSince(started),
                    .errors = 1,
                    .packets = packets,
                };
                const n = conn.read(buf[0..@min(buf.len, bytes - received)]) catch |err| switch (err) {
                    error.TimedOut,
                    error.EndOfStream,
                    error.ConnectionReset,
                    error.ConnectionRefused,
                    => return .{
                        .received_bytes = received,
                        .elapsed_ns = elapsedSince(started),
                        .errors = 1,
                        .packets = packets,
                    },
                    else => return err,
                };
                if (n == 0) break;
                received += n;
                packets +%= 1;
            }
            return .{
                .received_bytes = received,
                .elapsed_ns = elapsedSince(started),
                .packets = packets,
            };
        }

        fn pingConnServer(conn: Conn) !Protocol.Result {
            const started = grt.time.instant.now();
            var first = [_]u8{0xa5};
            var payload: [ping_payload_size]u8 = undefined;
            conn.setReadDeadline(glib.time.instant.add(started, transfer_timeout));
            conn.setWriteDeadline(glib.time.instant.add(started, transfer_timeout));
            defer conn.setReadDeadline(null);
            defer conn.setWriteDeadline(null);

            try writeAll(conn, &first);
            try readExact(conn, &payload);
            try writeAll(conn, &payload);
            return .{
                .sent_bytes = first.len + payload.len,
                .received_bytes = payload.len,
                .elapsed_ns = elapsedSince(started),
                .packets = 2,
            };
        }

        fn sendPacket(allocator: std.mem.Allocator, pc: PacketConn, remote: AddrPort, bytes: usize, chunk: usize) !Protocol.Result {
            const payload = try allocator.alloc(u8, chunk);
            defer allocator.free(payload);
            fillPattern(payload);
            const started = grt.time.instant.now();
            var sent: usize = 0;
            var packets: u32 = 0;
            while (sent < bytes) {
                const n = @min(payload.len, bytes - sent);
                const written = try pc.writeTo(payload[0..n], remote);
                sent += written;
                packets +%= 1;
            }
            return .{
                .sent_bytes = sent,
                .elapsed_ns = elapsedSince(started),
                .packets = packets,
            };
        }

        fn recvPacket(allocator: std.mem.Allocator, pc: PacketConn, bytes: usize, chunk: usize) !Protocol.Result {
            const payload = try allocator.alloc(u8, chunk);
            defer allocator.free(payload);
            const started = grt.time.instant.now();
            var received: usize = 0;
            var packets: u32 = 0;
            var errors: u32 = 0;
            defer pc.setReadDeadline(null);
            while (received < bytes) {
                if (elapsedSince(started) > transfer_timeout) {
                    errors +%= 1;
                    break;
                }
                pc.setReadDeadline(glib.time.instant.add(grt.time.instant.now(), udp_idle_timeout));
                const result = pc.readFrom(payload) catch |err| switch (err) {
                    error.TimedOut => {
                        errors +%= 1;
                        break;
                    },
                    else => return err,
                };
                received += result.bytes_read;
                packets +%= 1;
            }
            return .{
                .received_bytes = received,
                .elapsed_ns = elapsedSince(started),
                .errors = errors,
                .packets = packets,
            };
        }

        fn sendKcp(session: *Session, bytes: usize, chunk: usize) !Protocol.Result {
            var buf: [stream_write_buffer_size]u8 = undefined;
            fillPattern(&buf);
            const started = grt.time.instant.now();
            var sent: usize = 0;
            var packets: u32 = 0;
            var next_log: usize = @min(kcp_progress_interval_bytes, bytes);
            while (sent < bytes) {
                const n = @min(@min(chunk, buf.len), bytes - sent);
                const written = try session.write(buf[0..n]);
                sent += written;
                packets +%= 1;
                if (sent >= next_log or sent == bytes) {
                    logKcpProgress("ss", session, sent, bytes, started);
                    next_log = @min(next_log + kcp_progress_interval_bytes, bytes);
                }
            }
            return .{
                .sent_bytes = sent,
                .elapsed_ns = elapsedSince(started),
                .packets = packets,
            };
        }

        fn recvKcp(session: *Session, bytes: usize) !Protocol.Result {
            var buf: [stream_read_buffer_size]u8 = undefined;
            const started = grt.time.instant.now();
            var received: usize = 0;
            var packets: u32 = 0;
            var next_log: usize = @min(kcp_progress_interval_bytes, bytes);
            while (received < bytes) {
                if (elapsedSince(started) > transfer_timeout) {
                    logKcpProgress("sr_timeout", session, received, bytes, started);
                    return error.NetperfTransferTimeout;
                }
                const n = try session.read(buf[0..@min(buf.len, bytes - received)]);
                if (n == 0) {
                    grt.time.sleep(1 * glib.time.duration.MilliSecond);
                    continue;
                }
                received += n;
                packets +%= 1;
                if (received >= next_log or received == bytes) {
                    logKcpProgress("sr", session, received, bytes, started);
                    next_log = @min(next_log + kcp_progress_interval_bytes, bytes);
                }
            }
            return .{
                .received_bytes = received,
                .elapsed_ns = elapsedSince(started),
                .packets = packets,
            };
        }

        fn pingKcpServer(session: *Session) !Protocol.Result {
            const started = grt.time.instant.now();
            var first = [_]u8{0xa5};
            var payload: [ping_payload_size]u8 = undefined;
            _ = try session.write(&first);
            try readExactKcp(session, &payload, started);
            _ = try session.write(&payload);
            return .{
                .sent_bytes = first.len + payload.len,
                .received_bytes = payload.len,
                .elapsed_ns = elapsedSince(started),
                .packets = 2,
            };
        }

        fn duplexConn(conn: Conn, bytes: usize, chunk: usize) !Protocol.Result {
            return try duplexSplitConn(conn, conn, bytes, chunk);
        }

        fn duplexSplitConn(send_conn: Conn, recv_conn: Conn, bytes: usize, chunk: usize) !Protocol.Result {
            var send_result = ThreadResult{};
            var recv_result = ThreadResult{};
            var send_task = SendConnTask{ .conn = send_conn, .bytes = bytes, .chunk = chunk, .out = &send_result };
            var recv_task = RecvConnTask{ .conn = recv_conn, .bytes = bytes, .out = &recv_result };
            const send_handle = try grt.task.go("netperf/send", netperf_send_task_options, glib.task.Routine.init(&send_task, SendConnTask.run));
            const recv_handle = try grt.task.go("netperf/recv", netperf_recv_task_options, glib.task.Routine.init(&recv_task, RecvConnTask.run));
            send_handle.join();
            recv_handle.join();
            return mergeThreadResults(send_result, recv_result);
        }

        fn duplexPacket(allocator: std.mem.Allocator, pc: PacketConn, remote: AddrPort, bytes: usize, chunk: usize) !Protocol.Result {
            var send_result = ThreadResult{};
            var recv_result = ThreadResult{};
            var send_task = SendPacketTask{ .allocator = allocator, .pc = pc, .remote = remote, .bytes = bytes, .chunk = chunk, .out = &send_result };
            var recv_task = RecvPacketTask{ .allocator = allocator, .pc = pc, .bytes = bytes, .chunk = chunk, .out = &recv_result };
            const send_handle = try grt.task.go("netperf/send", netperf_send_task_options, glib.task.Routine.init(&send_task, SendPacketTask.run));
            const recv_handle = try grt.task.go("netperf/recv", netperf_recv_task_options, glib.task.Routine.init(&recv_task, RecvPacketTask.run));
            send_handle.join();
            recv_handle.join();
            return mergeThreadResults(send_result, recv_result);
        }

        fn duplexKcp(session: *Session, bytes: usize, chunk: usize) !Protocol.Result {
            var send_result = ThreadResult{};
            var recv_result = ThreadResult{};
            var send_task = SendKcpTask{ .session = session, .bytes = bytes, .chunk = chunk, .out = &send_result };
            var recv_task = RecvKcpTask{ .session = session, .bytes = bytes, .out = &recv_result };
            const send_handle = try grt.task.go("netperf/send", netperf_send_task_options, glib.task.Routine.init(&send_task, SendKcpTask.run));
            const recv_handle = try grt.task.go("netperf/recv", netperf_recv_task_options, glib.task.Routine.init(&recv_task, RecvKcpTask.run));
            send_handle.join();
            recv_handle.join();
            return mergeThreadResults(send_result, recv_result);
        }

        const ThreadResult = struct {
            result: Protocol.Result = .{},
            err: ?anyerror = null,
        };

        const DriveResult = struct {
            err: ?anyerror = null,
        };

        const DriveLoopTask = struct {
            session: *Session,
            stop: *AtomicBool,
            out: *DriveResult,

            fn run(self: *@This()) void {
                driveLoopThread(self.session, self.stop, self.out);
            }
        };

        const WriteLoopTask = struct {
            session: *Session,
            stop: *AtomicBool,
            out: *DriveResult,

            fn run(self: *@This()) void {
                writeLoopThread(self.session, self.stop, self.out);
            }
        };

        const ReadLoopTask = struct {
            session: *Session,
            stop: *AtomicBool,
            out: *DriveResult,

            fn run(self: *@This()) void {
                readLoopThread(self.session, self.stop, self.out);
            }
        };

        const SendConnTask = struct {
            conn: Conn,
            bytes: usize,
            chunk: usize,
            out: *ThreadResult,

            fn run(self: *@This()) void {
                sendConnThread(self.conn, self.bytes, self.chunk, self.out);
            }
        };

        const RecvConnTask = struct {
            conn: Conn,
            bytes: usize,
            out: *ThreadResult,

            fn run(self: *@This()) void {
                recvConnThread(self.conn, self.bytes, self.out);
            }
        };

        const SendPacketTask = struct {
            allocator: std.mem.Allocator,
            pc: PacketConn,
            remote: AddrPort,
            bytes: usize,
            chunk: usize,
            out: *ThreadResult,

            fn run(self: *@This()) void {
                sendPacketThread(self.allocator, self.pc, self.remote, self.bytes, self.chunk, self.out);
            }
        };

        const RecvPacketTask = struct {
            allocator: std.mem.Allocator,
            pc: PacketConn,
            bytes: usize,
            chunk: usize,
            out: *ThreadResult,

            fn run(self: *@This()) void {
                recvPacketThread(self.allocator, self.pc, self.bytes, self.chunk, self.out);
            }
        };

        const SendKcpTask = struct {
            session: *Session,
            bytes: usize,
            chunk: usize,
            out: *ThreadResult,

            fn run(self: *@This()) void {
                sendKcpThread(self.session, self.bytes, self.chunk, self.out);
            }
        };

        const RecvKcpTask = struct {
            session: *Session,
            bytes: usize,
            out: *ThreadResult,

            fn run(self: *@This()) void {
                recvKcpThread(self.session, self.bytes, self.out);
            }
        };

        fn sendConnThread(conn: Conn, bytes: usize, chunk: usize, out: *ThreadResult) void {
            out.result = sendConn(conn, bytes, chunk) catch |err| {
                out.err = err;
                return;
            };
        }

        fn recvConnThread(conn: Conn, bytes: usize, out: *ThreadResult) void {
            out.result = recvConn(conn, bytes) catch |err| {
                out.err = err;
                return;
            };
        }

        fn sendPacketThread(allocator: std.mem.Allocator, pc: PacketConn, remote: AddrPort, bytes: usize, chunk: usize, out: *ThreadResult) void {
            out.result = sendPacket(allocator, pc, remote, bytes, chunk) catch |err| {
                out.err = err;
                return;
            };
        }

        fn recvPacketThread(allocator: std.mem.Allocator, pc: PacketConn, bytes: usize, chunk: usize, out: *ThreadResult) void {
            out.result = recvPacket(allocator, pc, bytes, chunk) catch |err| {
                out.err = err;
                return;
            };
        }

        fn sendKcpThread(session: *Session, bytes: usize, chunk: usize, out: *ThreadResult) void {
            out.result = sendKcp(session, bytes, chunk) catch |err| {
                out.err = err;
                return;
            };
        }

        fn recvKcpThread(session: *Session, bytes: usize, out: *ThreadResult) void {
            out.result = recvKcp(session, bytes) catch |err| {
                out.err = err;
                return;
            };
        }

        fn driveLoopThread(session: *Session, stop: *AtomicBool, out: *DriveResult) void {
            session.driveLoop(stop) catch |err| {
                std.log.scoped(.netperf_kcp).err("drive loop failed: {s}", .{@errorName(err)});
                out.err = err;
                return;
            };
        }

        fn readLoopThread(session: *Session, stop: *AtomicBool, out: *DriveResult) void {
            session.readLoop(stop) catch |err| {
                std.log.scoped(.netperf_kcp).err("read loop failed: {s}", .{@errorName(err)});
                out.err = err;
                return;
            };
        }

        fn writeLoopThread(session: *Session, stop: *AtomicBool, out: *DriveResult) void {
            session.writeLoop(stop) catch |err| {
                std.log.scoped(.netperf_kcp).err("write loop failed: {s}", .{@errorName(err)});
                out.err = err;
                return;
            };
        }

        fn logKcpProgress(label: []const u8, session: *Session, done: usize, total: usize, started: glib.time.instant.Time) void {
            const snap = session.snapshot();
            const log = std.log.scoped(.netperf_kcp);
            const args = .{
                label,
                done,
                total,
                elapsedSince(started),
                snap.tx_bytes,
                snap.rx_bytes,
                snap.state.waitsnd,
                snap.state.room,
                snap.stats.udp_out_packets,
                snap.stats.udp_in_packets,
            };
            if (std.mem.indexOf(u8, label, "timeout") != null) {
                log.err("{s} {d}/{d} ns={d} tx={d} rx={d} ws={d} room={d} out={d} in={d}", args);
            } else {
                log.info("{s} {d}/{d} ns={d} tx={d} rx={d} ws={d} room={d} out={d} in={d}", args);
            }
        }

        fn mergeThreadResults(send_result: ThreadResult, recv_result: ThreadResult) !Protocol.Result {
            if (send_result.err) |err| return err;
            if (recv_result.err) |err| return err;
            return .{
                .sent_bytes = send_result.result.sent_bytes,
                .received_bytes = recv_result.result.received_bytes,
                .elapsed_ns = @max(send_result.result.elapsed_ns, recv_result.result.elapsed_ns),
                .errors = send_result.result.errors + recv_result.result.errors,
                .packets = send_result.result.packets + recv_result.result.packets,
            };
        }

        fn readLine(conn: Conn, out: []u8) ![]u8 {
            var used: usize = 0;
            while (used < out.len) {
                const n = try conn.read(out[used..][0..1]);
                if (n == 0) return error.EndOfStream;
                used += n;
                if (out[used - 1] == '\n') return out[0..used];
            }
            return error.LineTooLong;
        }

        fn writeAll(conn: Conn, buf: []const u8) !void {
            var offset: usize = 0;
            while (offset < buf.len) {
                const n = try conn.write(buf[offset..]);
                if (n == 0) return error.ShortWrite;
                offset += n;
            }
        }

        fn readExact(conn: Conn, buf: []u8) !void {
            var offset: usize = 0;
            while (offset < buf.len) {
                const n = try conn.read(buf[offset..]);
                if (n == 0) return error.EndOfStream;
                offset += n;
            }
        }

        fn readExactKcp(session: *Session, buf: []u8, started: glib.time.instant.Time) !void {
            var offset: usize = 0;
            while (offset < buf.len) {
                if (elapsedSince(started) > transfer_timeout) {
                    logKcpProgress("sre_timeout", session, offset, buf.len, started);
                    return error.NetperfTransferTimeout;
                }
                const n = try session.read(buf[offset..]);
                if (n == 0) {
                    grt.time.sleep(1 * glib.time.duration.MilliSecond);
                    continue;
                }
                offset += n;
            }
        }

        fn fillPattern(buf: []u8) void {
            for (buf, 0..) |*b, i| b.* = @truncate(i);
        }

        fn logUdpLoss(log: anytype, request: Protocol.Request, server_result: Protocol.Result, client_result: Protocol.Result) void {
            const expected = switch (request.direction) {
                .down => server_result.packets,
                .up => client_result.packets,
                .duplex => server_result.packets + client_result.packets,
                .ping => 0,
            };
            const received = switch (request.direction) {
                .down => client_result.packets,
                .up => server_result.packets,
                .duplex => server_result.packets + client_result.packets,
                .ping => 0,
            };
            const lost = expected -| received;
            const loss_rate = if (expected == 0)
                0.0
            else
                (@as(f64, @floatFromInt(lost)) * 100.0) / @as(f64, @floatFromInt(expected));
            log.info(
                "udp_loss expected_packets={d} received_packets={d} lost_packets={d} loss={d:.2}%",
                .{ expected, received, lost, loss_rate },
            );
        }

        fn elapsedSince(started: glib.time.instant.Time) u64 {
            const elapsed = glib.time.instant.sub(grt.time.instant.now(), started);
            if (elapsed <= 0) return 0;
            return @intCast(elapsed);
        }
    };
}
