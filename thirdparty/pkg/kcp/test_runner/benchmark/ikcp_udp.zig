const glib = @import("glib");
const kcp = @import("../../../kcp.zig");
const memory = @import("ikcp_memory.zig");

pub const Result = struct {
    rtt_ms: u32,
    elapsed_ns: u64,
    sent_bytes: usize,
    received_bytes: usize,
    output_packets: u64,
    output_bytes: u64,
    socket_send_packets: u64,
    socket_recv_packets: u64,
    output_drops: u64,
    input_errors: u64,
    loop_iterations: u64,
    kcp_send_calls: u64,
    kcp_input_calls: u64,
    kcp_update_calls: u64,
    kcp_recv_calls: u64,
    sleep_calls: u64,
    sleep_ms: u64,
    max_waitsnd: u32,
    max_inflight: u32,
    max_output_burst: u32,
    max_socket_send_burst: u32,
    max_socket_recv_burst: u32,
    max_send_queue_depth: usize,

    pub fn mbps(self: Result) f64 {
        if (self.elapsed_ns == 0) return 0;
        return (@as(f64, @floatFromInt(self.received_bytes)) * 8.0 * 1000.0) /
            @as(f64, @floatFromInt(self.elapsed_ns));
    }
};

pub fn Runner(comptime grt: type) type {
    const std = grt.std;
    const native_std = @import("std");
    const posix = std.posix;
    const packet_capacity = 1600;
    const delayed_queue_capacity = 512;
    const SegmentPool = kcp.SegmentPool.make(grt);

    return struct {
        pub fn runLocalhostRtt(allocator: std.mem.Allocator, config: memory.Config, rtt_ms: u32) !Result {
            if (config.udp_payload <= kcp.OVERHEAD or config.udp_payload > packet_capacity) {
                return error.IkcpUdpInvalidMtu;
            }
            if (config.send_window == 0 or config.recv_window == 0) return error.IkcpUdpInvalidWindow;

            var a_sock = try LocalUdpSocket.init();
            defer a_sock.deinit();
            var b_sock = try LocalUdpSocket.init();
            defer b_sock.deinit();

            var stats = Stats{};
            var a_queue = try DelayedPacketQueue.init(allocator);
            defer a_queue.deinit(allocator);
            var b_queue = try DelayedPacketQueue.init(allocator);
            defer b_queue.deinit(allocator);
            var a_pool = try SegmentPool.init(allocator, config.udp_payload - kcp.OVERHEAD, segmentPoolReserve(config));
            defer a_pool.deinit();
            var b_pool = try SegmentPool.init(allocator, config.udp_payload - kcp.OVERHEAD, segmentPoolReserve(config));
            defer b_pool.deinit();

            const started = grt.time.instant.now();
            var a = Peer{
                .sock = a_sock,
                .remote_addr = b_sock.addr,
                .start_at = started,
                .one_way_delay_ms = @divTrunc(rtt_ms, 2),
                .send_queue = &a_queue,
                .stats = &stats,
            };
            var b = Peer{
                .sock = b_sock,
                .remote_addr = a_sock.addr,
                .start_at = started,
                .one_way_delay_ms = rtt_ms - @divTrunc(rtt_ms, 2),
                .send_queue = &b_queue,
                .stats = &stats,
            };

            try initPeer(&a, config, a_pool.allocator());
            defer kcp.release(a.inst);
            try initPeer(&b, config, b_pool.allocator());
            defer kcp.release(b.inst);

            var send_buf: [1024]u8 = undefined;
            var recv_buf: [8192]u8 = undefined;
            fillPattern(&send_buf);

            var sent: usize = 0;
            var received: usize = 0;

            while (received < config.bytes) {
                stats.loop_iterations +%= 1;
                if (elapsedSince(started) > 30 * glib.time.duration.Second) return error.IkcpUdpTimeout;

                try sendDue(&a);
                try sendDue(&b);
                try pumpInput(&a);
                try pumpInput(&b);
                recordKcpState(&a);
                recordKcpState(&b);

                while (sent < config.bytes and kcp.waitsnd(a.inst) < config.send_window) {
                    const len = @min(send_buf.len, config.bytes - sent);
                    const rc = kcp.send(a.inst, send_buf[0..].ptr, @as(c_int, @intCast(len)));
                    if (rc < 0) return error.IkcpUdpSendFailed;
                    stats.kcp_send_calls +%= 1;
                    sent += @intCast(rc);
                    recordKcpState(&a);
                }

                updateIfDue(&a);
                updateIfDue(&b);
                try sendDue(&a);
                try sendDue(&b);
                try pumpInput(&a);
                try pumpInput(&b);
                received += drainRecv(b.inst, recv_buf[0..]);
                recordKcpState(&a);
                recordKcpState(&b);

                sleepUntilNext(&a, &b);
            }

            return .{
                .rtt_ms = rtt_ms,
                .elapsed_ns = elapsedSince(started),
                .sent_bytes = sent,
                .received_bytes = received,
                .output_packets = stats.output_packets,
                .output_bytes = stats.output_bytes,
                .socket_send_packets = stats.socket_send_packets,
                .socket_recv_packets = stats.socket_recv_packets,
                .output_drops = stats.output_drops,
                .input_errors = stats.input_errors,
                .loop_iterations = stats.loop_iterations,
                .kcp_send_calls = stats.kcp_send_calls,
                .kcp_input_calls = stats.kcp_input_calls,
                .kcp_update_calls = stats.kcp_update_calls,
                .kcp_recv_calls = stats.kcp_recv_calls,
                .sleep_calls = stats.sleep_calls,
                .sleep_ms = stats.sleep_ms,
                .max_waitsnd = stats.max_waitsnd,
                .max_inflight = stats.max_inflight,
                .max_output_burst = stats.max_output_burst,
                .max_socket_send_burst = stats.max_socket_send_burst,
                .max_socket_recv_burst = stats.max_socket_recv_burst,
                .max_send_queue_depth = stats.max_send_queue_depth,
            };
        }

        fn initPeer(peer: *Peer, config: memory.Config, alloc: kcp.Allocator) !void {
            peer.inst = kcp.createWithAllocator(0x55667788, peer, alloc) orelse return error.IkcpUdpCreateFailed;
            errdefer kcp.release(peer.inst);
            kcp.setOutput(peer.inst, output);
            if (kcp.setMtu(peer.inst, @as(c_int, @intCast(config.udp_payload))) != 0) return error.IkcpUdpSetMtuFailed;
            if (kcp.nodelay(peer.inst, config.nodelay, @as(c_int, @intCast(config.interval_ms)), config.resend, config.no_congestion_control) != 0) {
                return error.IkcpUdpNodelayFailed;
            }
            if (kcp.wndsize(peer.inst, @as(c_int, @intCast(config.send_window)), @as(c_int, @intCast(config.recv_window))) != 0) {
                return error.IkcpUdpWndsizeFailed;
            }
            peer.inst.*.stream = 1;
            peer.inst.*.current = nowMs(peer.start_at);
            kcp.update(peer.inst, peer.inst.*.current);
        }

        fn output(buf: [*c]const u8, len: c_int, inst: [*c]kcp.Kcp, user: ?*anyopaque) callconv(.c) c_int {
            _ = inst;
            if (len < 0) return -1;
            const peer: *Peer = @ptrCast(@alignCast(user orelse return -1));
            const frame = buf[0..@intCast(len)];
            if (frame.len < kcp.OVERHEAD) {
                peer.stats.output_drops +%= 1;
                return -1;
            }
            peer.stats.output_packets +%= 1;
            peer.stats.output_bytes +%= frame.len;
            peer.stats.current_output_burst +%= 1;
            peer.stats.max_output_burst = @max(peer.stats.max_output_burst, peer.stats.current_output_burst);
            peer.send_queue.push(frame, nowMs(peer.start_at) +| peer.one_way_delay_ms) catch {
                peer.stats.output_drops +%= 1;
                return -1;
            };
            peer.stats.max_send_queue_depth = @max(peer.stats.max_send_queue_depth, peer.send_queue.len);
            return len;
        }

        fn sendDue(peer: *Peer) !void {
            const current = nowMs(peer.start_at);
            var burst: u32 = 0;
            while (peer.send_queue.peekDue(current)) |packet| {
                const written = try posix.sendto(
                    peer.sock.fd,
                    packet.data[0..packet.len],
                    0,
                    &peer.remote_addr.any,
                    peer.remote_addr.getOsSockLen(),
                );
                if (written != packet.len) return error.IkcpUdpShortSocketWrite;
                peer.stats.socket_send_packets +%= 1;
                burst += 1;
                peer.send_queue.discard();
            }
            peer.stats.max_socket_send_burst = @max(peer.stats.max_socket_send_burst, burst);
        }

        fn pumpInput(peer: *Peer) !void {
            var packet: [packet_capacity]u8 = undefined;
            var reads: usize = 0;
            while (reads < 64) : (reads += 1) {
                var src: posix.sockaddr.storage = undefined;
                var src_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
                const len = posix.recvfrom(peer.sock.fd, packet[0..], 0, @ptrCast(&src), &src_len) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => return err,
                };
                if (len < kcp.OVERHEAD) continue;
                peer.inst.*.current = nowMs(peer.start_at);
                const rc = kcp.input(peer.inst, packet[0..len].ptr, len);
                if (rc != 0) {
                    peer.stats.input_errors +%= 1;
                    return error.IkcpUdpInputFailed;
                }
                peer.stats.kcp_input_calls +%= 1;
                peer.stats.socket_recv_packets +%= 1;
            }
            peer.stats.max_socket_recv_burst = @max(peer.stats.max_socket_recv_burst, @as(u32, @intCast(reads)));
        }

        fn updateIfDue(peer: *Peer) void {
            const current = nowMs(peer.start_at);
            peer.inst.*.current = current;
            if (timeReached(current, kcp.check(peer.inst, current))) {
                peer.stats.kcp_update_calls +%= 1;
                peer.stats.current_output_burst = 0;
                kcp.update(peer.inst, current);
                recordKcpState(peer);
            }
        }

        fn drainRecv(inst: *kcp.Kcp, buf: []u8) usize {
            var received: usize = 0;
            while (true) {
                const len = kcp.recv(inst, buf.ptr, @as(c_int, @intCast(buf.len)));
                if (len <= 0) return received;
                received += @intCast(len);
                // The benchmark only drains app bytes on the receiver endpoint,
                // so the active stats object is reached through KCP's user pointer.
                const peer: *Peer = @ptrCast(@alignCast(inst.user));
                peer.stats.kcp_recv_calls +%= 1;
            }
        }

        fn sleepUntilNext(a: *Peer, b: *Peer) void {
            const current = nowMs(a.start_at);
            var wait_ms: u32 = 1;
            wait_ms = @min(wait_ms, waitForKcp(a, current));
            wait_ms = @min(wait_ms, waitForKcp(b, current));
            wait_ms = @min(wait_ms, a.send_queue.waitMs(current));
            wait_ms = @min(wait_ms, b.send_queue.waitMs(current));
            if (wait_ms == 0) return;
            a.stats.sleep_calls +%= 1;
            a.stats.sleep_ms +%= wait_ms;
            grt.time.sleep(@as(glib.time.duration.Duration, wait_ms) * glib.time.duration.MilliSecond);
        }

        fn waitForKcp(peer: *Peer, current: u32) u32 {
            const next = kcp.check(peer.inst, current);
            if (timeReached(current, next)) return 0;
            return next -% current;
        }

        fn segmentPoolReserve(config: memory.Config) usize {
            return @as(usize, @intCast(config.send_window)) +
                @as(usize, @intCast(config.recv_window)) +
                16;
        }

        fn recordKcpState(peer: *Peer) void {
            const waitsnd = kcp.waitsnd(peer.inst);
            if (waitsnd > 0) peer.stats.max_waitsnd = @max(peer.stats.max_waitsnd, @as(u32, @intCast(waitsnd)));
            const inflight = peer.inst.*.snd_nxt -% peer.inst.*.snd_una;
            peer.stats.max_inflight = @max(peer.stats.max_inflight, inflight);
            peer.stats.max_send_queue_depth = @max(peer.stats.max_send_queue_depth, peer.send_queue.len);
        }

        fn fillPattern(buf: []u8) void {
            for (buf, 0..) |*byte, i| byte.* = @truncate(i);
        }

        fn nowMs(started: glib.time.instant.Time) u32 {
            const elapsed = glib.time.instant.sub(grt.time.instant.now(), started);
            if (elapsed <= 0) return 0;
            return @truncate(@as(u64, @intCast(@divTrunc(elapsed, glib.time.duration.MilliSecond))));
        }

        fn elapsedSince(started: glib.time.instant.Time) u64 {
            const elapsed = glib.time.instant.sub(grt.time.instant.now(), started);
            if (elapsed <= 0) return 0;
            return @intCast(elapsed);
        }

        fn timeReached(now_ms: u32, target_ms: u32) bool {
            return @as(i32, @bitCast(now_ms -% target_ms)) >= 0;
        }

        const Stats = struct {
            output_packets: u64 = 0,
            output_bytes: u64 = 0,
            socket_send_packets: u64 = 0,
            socket_recv_packets: u64 = 0,
            output_drops: u64 = 0,
            input_errors: u64 = 0,
            loop_iterations: u64 = 0,
            kcp_send_calls: u64 = 0,
            kcp_input_calls: u64 = 0,
            kcp_update_calls: u64 = 0,
            kcp_recv_calls: u64 = 0,
            sleep_calls: u64 = 0,
            sleep_ms: u64 = 0,
            max_waitsnd: u32 = 0,
            max_inflight: u32 = 0,
            current_output_burst: u32 = 0,
            max_output_burst: u32 = 0,
            max_socket_send_burst: u32 = 0,
            max_socket_recv_burst: u32 = 0,
            max_send_queue_depth: usize = 0,
        };

        const Packet = struct {
            len: usize = 0,
            due_ms: u32 = 0,
            data: [packet_capacity]u8 = [_]u8{0} ** packet_capacity,
        };

        const DelayedPacketQueue = struct {
            items: []Packet,
            head: usize = 0,
            len: usize = 0,

            fn init(allocator: std.mem.Allocator) !DelayedPacketQueue {
                return .{ .items = try allocator.alloc(Packet, delayed_queue_capacity) };
            }

            fn deinit(self: *DelayedPacketQueue, allocator: std.mem.Allocator) void {
                allocator.free(self.items);
                self.* = undefined;
            }

            fn push(self: *DelayedPacketQueue, frame: []const u8, due_ms: u32) !void {
                if (frame.len > packet_capacity) return error.IkcpUdpPacketTooLarge;
                if (self.len == self.items.len) return error.IkcpUdpQueueFull;
                const pos = (self.head + self.len) % self.items.len;
                self.items[pos].len = frame.len;
                self.items[pos].due_ms = due_ms;
                @memcpy(self.items[pos].data[0..frame.len], frame);
                self.len += 1;
            }

            fn peekDue(self: *DelayedPacketQueue, current_ms: u32) ?*const Packet {
                if (self.len == 0) return null;
                const packet = &self.items[self.head];
                if (!timeReached(current_ms, packet.due_ms)) return null;
                return packet;
            }

            fn waitMs(self: *DelayedPacketQueue, current_ms: u32) u32 {
                if (self.len == 0) return 1;
                const due_ms = self.items[self.head].due_ms;
                if (timeReached(current_ms, due_ms)) return 0;
                return due_ms -% current_ms;
            }

            fn discard(self: *DelayedPacketQueue) void {
                if (self.len == 0) return;
                self.head = (self.head + 1) % self.items.len;
                self.len -= 1;
            }
        };

        const LocalUdpSocket = struct {
            fd: posix.socket_t,
            addr: native_std.net.Address,

            fn init() !LocalUdpSocket {
                const fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, posix.IPPROTO.UDP);
                errdefer posix.close(fd);

                var addr = try native_std.net.Address.parseIp4("127.0.0.1", 0);
                try posix.bind(fd, &addr.any, addr.getOsSockLen());

                var storage: posix.sockaddr.storage = undefined;
                var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
                try posix.getsockname(fd, @ptrCast(&storage), &len);
                const bound = native_std.net.Address.initPosix(@ptrCast(@alignCast(&storage)));
                return .{ .fd = fd, .addr = bound };
            }

            fn deinit(self: *LocalUdpSocket) void {
                posix.close(self.fd);
                self.* = undefined;
            }
        };

        const Peer = struct {
            inst: *kcp.Kcp = undefined,
            sock: LocalUdpSocket,
            remote_addr: native_std.net.Address,
            start_at: glib.time.instant.Time,
            one_way_delay_ms: u32,
            send_queue: *DelayedPacketQueue,
            stats: *Stats,
        };
    };
}
