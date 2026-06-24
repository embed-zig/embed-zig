const glib = @import("glib");
const kcp = @import("../../../kcp.zig");

pub const default_bytes: usize = 5 * 1024 * 1024;
pub const default_udp_payload: usize = 1400;
pub const default_window: u32 = 64;
pub const default_interval_ms: u32 = 10;

pub const Scenario = enum {
    stream_up,
    packet_up,
    stream_duplex,

    pub fn label(self: Scenario) []const u8 {
        return switch (self) {
            .stream_up => "stream-up",
            .packet_up => "packet-up",
            .stream_duplex => "stream-duplex",
        };
    }

    fn stream(self: Scenario) bool {
        return switch (self) {
            .stream_up, .stream_duplex => true,
            .packet_up => false,
        };
    }

    fn duplex(self: Scenario) bool {
        return self == .stream_duplex;
    }
};

pub const Config = struct {
    bytes: usize = default_bytes,
    udp_payload: usize = default_udp_payload,
    send_window: u32 = default_window,
    recv_window: u32 = default_window,
    nodelay: i32 = 1,
    interval_ms: u32 = default_interval_ms,
    resend: i32 = 2,
    no_congestion_control: i32 = 1,
};

pub const Result = struct {
    scenario: Scenario,
    elapsed_ns: u64,
    sent_bytes: usize,
    received_bytes: usize,
    output_packets: u64,
    output_bytes: u64,
    output_drops: u64,
    input_errors: u64,

    pub fn mbps(self: Result) f64 {
        if (self.elapsed_ns == 0) return 0;
        return (@as(f64, @floatFromInt(self.received_bytes)) * 8.0 * 1000.0) /
            @as(f64, @floatFromInt(self.elapsed_ns));
    }
};

pub fn Runner(comptime grt: type) type {
    const std = grt.std;
    const packet_capacity = 1600;
    const queue_capacity = 128;
    const SegmentPool = kcp.SegmentPool.make(grt);

    return struct {
        pub fn runAll(allocator: std.mem.Allocator, config: Config, out: []Result) !usize {
            const scenarios = [_]Scenario{ .stream_up, .packet_up, .stream_duplex };
            var len: usize = 0;
            for (scenarios) |scenario| {
                if (len >= out.len) return error.IkcpMemoryOutputTooSmall;
                out[len] = try runScenario(allocator, config, scenario);
                len += 1;
            }
            return len;
        }

        pub fn runScenario(allocator: std.mem.Allocator, config: Config, scenario: Scenario) !Result {
            if (config.udp_payload <= kcp.OVERHEAD or config.udp_payload > packet_capacity) {
                return error.IkcpMemoryInvalidMtu;
            }
            if (config.send_window == 0 or config.recv_window == 0) return error.IkcpMemoryInvalidWindow;

            var stats = Stats{};
            var a_inbox = try PacketQueue.init(allocator);
            defer a_inbox.deinit(allocator);
            var b_inbox = try PacketQueue.init(allocator);
            defer b_inbox.deinit(allocator);
            var a_pool = try SegmentPool.init(allocator, config.udp_payload - kcp.OVERHEAD, segmentPoolReserve(config));
            defer a_pool.deinit();
            var b_pool = try SegmentPool.init(allocator, config.udp_payload - kcp.OVERHEAD, segmentPoolReserve(config));
            defer b_pool.deinit();

            var a = Peer{ .inbox = &a_inbox, .stats = &stats };
            var b = Peer{ .inbox = &b_inbox, .stats = &stats };
            a.remote = &b;
            b.remote = &a;

            try initPeer(&a, config, scenario.stream(), a_pool.allocator());
            defer kcp.release(a.inst);
            try initPeer(&b, config, scenario.stream(), b_pool.allocator());
            defer kcp.release(b.inst);

            var send_buf: [1024]u8 = undefined;
            var recv_buf: [8192]u8 = undefined;
            fillPattern(&send_buf);

            const started = grt.time.instant.now();
            var current: u32 = 0;
            var a_sent: usize = 0;
            var b_sent: usize = 0;
            var a_recv: usize = 0;
            var b_recv: usize = 0;
            const b_send_total: usize = if (scenario.duplex()) config.bytes else 0;

            while (b_recv < config.bytes or a_recv < b_send_total) {
                try pumpInput(&a);
                try pumpInput(&b);

                while (a_sent < config.bytes and kcp.waitsnd(a.inst) < config.send_window) {
                    const len = @min(send_buf.len, config.bytes - a_sent);
                    const sent = kcp.send(a.inst, send_buf[0..].ptr, @as(c_int, @intCast(len)));
                    if (sent < 0) return error.IkcpMemorySendFailed;
                    a_sent += @intCast(sent);
                }
                while (scenario.duplex() and b_sent < config.bytes and kcp.waitsnd(b.inst) < config.send_window) {
                    const len = @min(send_buf.len, config.bytes - b_sent);
                    const sent = kcp.send(b.inst, send_buf[0..].ptr, @as(c_int, @intCast(len)));
                    if (sent < 0) return error.IkcpMemorySendFailed;
                    b_sent += @intCast(sent);
                }

                a.inst.*.current = current;
                b.inst.*.current = current;
                kcp.update(a.inst, current);
                kcp.update(b.inst, current);
                try pumpInput(&a);
                try pumpInput(&b);
                b_recv += drainRecv(b.inst, recv_buf[0..]);
                a_recv += drainRecv(a.inst, recv_buf[0..]);

                current +%= config.interval_ms;
            }

            return .{
                .scenario = scenario,
                .elapsed_ns = elapsedSince(started),
                .sent_bytes = a_sent + b_sent,
                .received_bytes = a_recv + b_recv,
                .output_packets = stats.output_packets,
                .output_bytes = stats.output_bytes,
                .output_drops = stats.output_drops,
                .input_errors = stats.input_errors,
            };
        }

        fn initPeer(peer: *Peer, config: Config, stream: bool, alloc: kcp.Allocator) !void {
            peer.inst = kcp.createWithAllocator(0x11223344, peer, alloc) orelse return error.IkcpMemoryCreateFailed;
            errdefer kcp.release(peer.inst);
            kcp.setOutput(peer.inst, output);
            if (kcp.setMtu(peer.inst, @as(c_int, @intCast(config.udp_payload))) != 0) return error.IkcpMemorySetMtuFailed;
            if (kcp.nodelay(peer.inst, config.nodelay, @as(c_int, @intCast(config.interval_ms)), config.resend, config.no_congestion_control) != 0) {
                return error.IkcpMemoryNodelayFailed;
            }
            if (kcp.wndsize(peer.inst, @as(c_int, @intCast(config.send_window)), @as(c_int, @intCast(config.recv_window))) != 0) {
                return error.IkcpMemoryWndsizeFailed;
            }
            peer.inst.*.stream = if (stream) 1 else 0;
            kcp.update(peer.inst, 0);
        }

        fn output(buf: [*c]const u8, len: c_int, inst: [*c]kcp.Kcp, user: ?*anyopaque) callconv(.c) c_int {
            _ = inst;
            if (len < 0) return -1;
            const peer: *Peer = @ptrCast(@alignCast(user orelse return -1));
            const frame = buf[0..@intCast(len)];
            if (frame.len == 0) return 0;
            if (frame.len < kcp.OVERHEAD) {
                peer.stats.output_drops +%= 1;
                return -1;
            }
            peer.stats.output_packets +%= 1;
            peer.stats.output_bytes +%= frame.len;
            peer.remote.inbox.push(frame) catch {
                peer.stats.output_drops +%= 1;
                return -1;
            };
            return len;
        }

        fn pumpInput(peer: *Peer) !void {
            while (peer.inbox.peek()) |packet| {
                const ret = kcp.input(peer.inst, packet.data[0..packet.len].ptr, packet.len);
                if (ret != 0) {
                    peer.stats.input_errors +%= 1;
                    return error.IkcpMemoryInputFailed;
                }
                peer.inbox.discard();
            }
        }

        fn drainRecv(inst: *kcp.Kcp, buf: []u8) usize {
            var received: usize = 0;
            while (true) {
                const len = kcp.recv(inst, buf.ptr, @as(c_int, @intCast(buf.len)));
                if (len <= 0) return received;
                received += @intCast(len);
            }
        }

        fn segmentPoolReserve(config: Config) usize {
            return @as(usize, @intCast(config.send_window)) +
                @as(usize, @intCast(config.recv_window)) +
                16;
        }

        fn fillPattern(buf: []u8) void {
            for (buf, 0..) |*byte, i| byte.* = @truncate(i);
        }

        fn elapsedSince(started: glib.time.instant.Time) u64 {
            const elapsed = glib.time.instant.sub(grt.time.instant.now(), started);
            if (elapsed <= 0) return 0;
            return @intCast(elapsed);
        }

        const Stats = struct {
            output_packets: u64 = 0,
            output_bytes: u64 = 0,
            output_drops: u64 = 0,
            input_errors: u64 = 0,
        };

        const Packet = struct {
            len: usize = 0,
            data: [packet_capacity]u8 = [_]u8{0} ** packet_capacity,
        };

        const PacketQueue = struct {
            items: []Packet,
            head: usize = 0,
            len: usize = 0,

            fn init(allocator: std.mem.Allocator) !PacketQueue {
                return .{ .items = try allocator.alloc(Packet, queue_capacity) };
            }

            fn deinit(self: *PacketQueue, allocator: std.mem.Allocator) void {
                allocator.free(self.items);
                self.* = undefined;
            }

            fn push(self: *PacketQueue, frame: []const u8) !void {
                if (frame.len > packet_capacity) return error.IkcpMemoryPacketTooLarge;
                if (self.len == self.items.len) return error.IkcpMemoryQueueFull;
                const pos = (self.head + self.len) % self.items.len;
                self.items[pos].len = frame.len;
                @memcpy(self.items[pos].data[0..frame.len], frame);
                self.len += 1;
            }

            fn peek(self: *PacketQueue) ?*const Packet {
                if (self.len == 0) return null;
                return &self.items[self.head];
            }

            fn discard(self: *PacketQueue) void {
                if (self.len == 0) return;
                self.head = (self.head + 1) % self.items.len;
                self.len -= 1;
            }
        };

        const Peer = struct {
            inst: *kcp.Kcp = undefined,
            remote: *Peer = undefined,
            inbox: *PacketQueue,
            stats: *Stats,
        };
    };
}
