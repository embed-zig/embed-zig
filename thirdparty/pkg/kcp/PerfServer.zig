const glib = @import("glib");
const Protocol = @import("PerfProtocol.zig");
const PerfEndpointFile = @import("PerfEndpoint.zig");

const AddrPort = glib.net.netip.AddrPort;
const transfer_timeout = 180 * glib.time.duration.Second;
const udp_idle_timeout = 2 * glib.time.duration.Second;
const stream_write_buffer_size = 8192;
const stream_read_buffer_size = 1440;
const ping_payload_size = 8;
const udp_pace_min_sleep = 1 * glib.time.duration.MilliSecond;
const default_udp_socket_buffer_size = 4 * 1024 * 1024;
const default_tcp_socket_buffer_size = 48 * 1600;
const netperf_send_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };
const netperf_recv_task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 };

pub fn make(comptime grt: type) type {
    const std = grt.std;
    const Net = grt.net;
    const Conn = Net.Conn;
    const PacketConn = Net.PacketConn;
    const PerfEndpoint = PerfEndpointFile.make(grt);

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
                .ikcp_packet, .ikcp_stream => try self.runKcp(control, request),
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
            var endpoint: PerfEndpoint = undefined;
            try endpoint.init(self.allocator, pc, remote, request.conv, request, protocolMode(request.protocol));
            defer endpoint.deinit();

            const result = endpoint.run(.server, request, null) catch |err| {
                drainControlDiagnostics(control);
                return err;
            };
            try finish(control, request, result);
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
                .down => try sendPacket(allocator, pc, remote, request.bytes, request.udpPayload(), request.udp_pps),
                .up => try recvPacket(allocator, pc, request.bytes, request.udpPayload()),
                .duplex => try duplexPacket(allocator, pc, remote, request.bytes, request.udpPayload(), request.udp_pps),
                .ping => error.UnsupportedProtocolDirection,
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
            const log = std.log.scoped(.netperf_server);
            const client_result = while (true) {
                const line = try readLine(control, &line_buf);
                if (Protocol.isDiagLine(std, line)) {
                    log.warn("client_diag {s}", .{Protocol.trimLine(std, line)});
                    continue;
                }
                break try Protocol.parseStop(std, line);
            };
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

        fn drainControlDiagnostics(control: Conn) void {
            const log = std.log.scoped(.netperf_server);
            var line_buf: [Protocol.max_line_len]u8 = undefined;
            control.setReadDeadline(glib.time.instant.add(grt.time.instant.now(), 20 * glib.time.duration.MilliSecond));
            defer control.setReadDeadline(null);
            while (true) {
                const line = readLine(control, &line_buf) catch |err| switch (err) {
                    error.TimedOut,
                    error.EndOfStream,
                    error.ConnectionReset,
                    error.ConnectionRefused,
                    error.BrokenPipe,
                    => return,
                    else => {
                        log.warn("client_diag drain failed err={s}", .{@errorName(err)});
                        return;
                    },
                };
                if (Protocol.isDiagLine(std, line)) {
                    log.warn("client_diag {s}", .{Protocol.trimLine(std, line)});
                    continue;
                }
                log.warn("client_control_after_error {s}", .{Protocol.trimLine(std, line)});
            }
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

        fn sendPacket(allocator: std.mem.Allocator, pc: PacketConn, remote: AddrPort, bytes: usize, chunk: usize, udp_pps: u32) !Protocol.Result {
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
                paceUdpPacket(started, packets, udp_pps);
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
            var active_elapsed_ns: u64 = 0;
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
                active_elapsed_ns = elapsedSince(started);
            }
            return .{
                .received_bytes = received,
                .elapsed_ns = if (active_elapsed_ns != 0) active_elapsed_ns else elapsedSince(started),
                .errors = errors,
                .packets = packets,
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

        fn duplexPacket(allocator: std.mem.Allocator, pc: PacketConn, remote: AddrPort, bytes: usize, chunk: usize, udp_pps: u32) !Protocol.Result {
            var send_result = ThreadResult{};
            var recv_result = ThreadResult{};
            var send_task = SendPacketTask{ .allocator = allocator, .pc = pc, .remote = remote, .bytes = bytes, .chunk = chunk, .udp_pps = udp_pps, .out = &send_result };
            var recv_task = RecvPacketTask{ .allocator = allocator, .pc = pc, .bytes = bytes, .chunk = chunk, .out = &recv_result };
            const send_handle = try grt.task.go("netperf/send", netperf_send_task_options, glib.task.Routine.init(&send_task, SendPacketTask.run));
            const recv_handle = try grt.task.go("netperf/recv", netperf_recv_task_options, glib.task.Routine.init(&recv_task, RecvPacketTask.run));
            send_handle.join();
            recv_handle.join();
            return mergeThreadResults(send_result, recv_result);
        }

        const ThreadResult = struct {
            result: Protocol.Result = .{},
            err: ?anyerror = null,
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
            udp_pps: u32,
            out: *ThreadResult,

            fn run(self: *@This()) void {
                sendPacketThread(self.allocator, self.pc, self.remote, self.bytes, self.chunk, self.udp_pps, self.out);
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

        fn sendPacketThread(allocator: std.mem.Allocator, pc: PacketConn, remote: AddrPort, bytes: usize, chunk: usize, udp_pps: u32, out: *ThreadResult) void {
            out.result = sendPacket(allocator, pc, remote, bytes, chunk, udp_pps) catch |err| {
                out.err = err;
                return;
            };
        }

        fn paceUdpPacket(started: glib.time.instant.Time, packets: u32, udp_pps: u32) void {
            if (udp_pps == 0) return;
            const target_ns = (@as(u64, packets) * @as(u64, @intCast(glib.time.duration.Second))) / udp_pps;
            const elapsed_ns = elapsedSince(started);
            if (target_ns <= elapsed_ns) return;
            const wait_ns = target_ns - elapsed_ns;
            if (wait_ns < udp_pace_min_sleep) return;
            grt.time.sleep(@intCast(wait_ns));
        }

        fn recvPacketThread(allocator: std.mem.Allocator, pc: PacketConn, bytes: usize, chunk: usize, out: *ThreadResult) void {
            out.result = recvPacket(allocator, pc, bytes, chunk) catch |err| {
                out.err = err;
                return;
            };
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

        fn fillPattern(buf: []u8) void {
            for (buf, 0..) |*b, i| b.* = @truncate(i);
        }

        fn protocolMode(protocol: Protocol.Protocol) PerfEndpointFile.Mode {
            return switch (protocol) {
                .ikcp_packet => .packet,
                .ikcp_stream => .stream,
                .tcp, .udp => unreachable,
            };
        }

        fn logUdpLoss(log: anytype, request: Protocol.Request, server_result: Protocol.Result, client_result: Protocol.Result) void {
            const expected = switch (request.direction) {
                .down => udpDatagramsForBytes(server_result.sent_bytes, request.udpPayload()),
                .up => udpDatagramsForBytes(client_result.sent_bytes, request.udpPayload()),
                .duplex => udpDatagramsForBytes(server_result.sent_bytes, request.udpPayload()) +
                    udpDatagramsForBytes(client_result.sent_bytes, request.udpPayload()),
                .ping => 0,
            };
            const received = switch (request.direction) {
                .down => udpDatagramsForBytes(client_result.received_bytes, request.udpPayload()),
                .up => udpDatagramsForBytes(server_result.received_bytes, request.udpPayload()),
                .duplex => udpDatagramsForBytes(server_result.received_bytes, request.udpPayload()) +
                    udpDatagramsForBytes(client_result.received_bytes, request.udpPayload()),
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

        fn udpDatagramsForBytes(bytes: usize, payload: usize) usize {
            if (bytes == 0) return 0;
            return (bytes + payload - 1) / payload;
        }

        fn elapsedSince(started: glib.time.instant.Time) u64 {
            const elapsed = glib.time.instant.sub(grt.time.instant.now(), started);
            if (elapsed <= 0) return 0;
            return @intCast(elapsed);
        }
    };
}
