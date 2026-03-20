//! Resolver — pure-Zig DNS resolver (Go's net.Resolver).
//!
//! Builds and parses DNS wire-format packets (RFC 1035) directly.
//! No libc getaddrinfo, fully portable across embed platforms.
//!
//! Strategy (worker pool):
//!   1. Build query packets (A, AAAA depending on mode)
//!   2. Create a task queue: one task per configured server
//!   3. Spawn N worker threads (default 2); each worker:
//!      a. Atomically claims the next server from the queue
//!      b. Sends all query packets via the server's protocol (UDP/TCP)
//!      c. Waits for responses with SO_RCVTIMEO
//!      d. On success → writes result, sets done flag
//!      e. On failure → loops back to (a) for next server
//!   4. Main thread joins workers, returns first successful result
//!   5. If all servers fail → Timeout

const udp_conn = @import("UdpConn.zig");

pub fn Resolver(comptime lib: type) type {
    const posix = lib.posix;
    const Addr = lib.net.Address;
    const UdpConn = udp_conn.UdpConn(lib);
    const mem = lib.mem;
    const Allocator = mem.Allocator;
    const Thread = lib.Thread;
    const Atomic = lib.atomic.Value;

    return struct {
        options: Options,

        const Self = @This();

        pub const Protocol = enum(u3) {
            udp = 0,
            tcp = 1,
            tls = 2,
            doh = 3,
        };

        pub const Server = struct {
            addr: Addr,
            protocol: Protocol = .udp,

            pub fn init(comptime ip: []const u8, comptime protocol: Protocol) Server {
                const port: u16 = comptime switch (protocol) {
                    .udp, .tcp => 53,
                    .tls => 853,
                    .doh => 443,
                };
                return .{ .addr = comptime Addr.parseIp(ip, port) catch unreachable, .protocol = protocol };
            }
        };

        pub const dns = struct {
            pub const ali = struct {
                pub const v4_1 = "223.5.5.5";
                pub const v4_2 = "223.6.6.6";
                pub const v6_1 = "2400:3200::1";
                pub const v6_2 = "2400:3200:baba::1";
            };
            pub const google = struct {
                pub const v4_1 = "8.8.8.8";
                pub const v4_2 = "8.8.4.4";
                pub const v6_1 = "2001:4860:4860::8888";
                pub const v6_2 = "2001:4860:4860::8844";
            };
            pub const cloudflare = struct {
                pub const v4_1 = "1.1.1.1";
                pub const v4_2 = "1.0.0.1";
                pub const v6_1 = "2606:4700:4700::1111";
                pub const v6_2 = "2606:4700:4700::1001";
            };
            pub const quad9 = struct {
                pub const v4_1 = "9.9.9.9";
                pub const v4_2 = "149.112.112.112";
            };
        };

        pub const Options = struct {
            servers: []const Server = &.{
                Server.init(dns.ali.v4_1, .udp),
                Server.init(dns.cloudflare.v4_1, .udp),
                Server.init(dns.ali.v4_2, .udp),
                Server.init(dns.cloudflare.v4_2, .udp),
            },
            timeout_ms: u32 = 1000,
            attempts: u32 = 2,
            mode: QueryMode = .ipv4_and_ipv6,
            concurrency: u32 = 2,
            spawn_config: Thread.SpawnConfig = .{},
        };

        pub const QueryMode = enum {
            ipv4_only,
            ipv6_only,
            ipv4_and_ipv6,
        };

        pub const LookupError = error{
            NameNotFound,
            Refused,
            Timeout,
            InvalidResponse,
            NoServerConfigured,
            OutOfMemory,
        } || posix.SocketError || posix.SendToError || posix.RecvFromError ||
            posix.ConnectError || posix.SendError || posix.SetSockOptError ||
            Thread.SpawnError;

        pub fn init(options: Options) Self {
            return .{ .options = options };
        }

        const MAX_ADDRS = 16;

        const WorkerResult = struct {
            addrs: [MAX_ADDRS]Addr = undefined,
            count: usize = 0,
            err: ?LookupError = null,
            has_result: bool = false,
        };

        const SharedState = struct {
            next_task: Atomic(usize),
            done: Atomic(bool),
            mutex: Thread.Mutex,
            result: WorkerResult,
            servers: []const Server,
            query_pkts: []const QueryPkt,
            timeout_ms: u32,
            attempts: u32,
        };

        const QueryPkt = struct {
            buf: [512]u8,
            len: usize,
            qtype: u16,
            id: u16,
        };

        pub fn lookupHost(self: Self, allocator: Allocator, name: []const u8, buf: []Addr) LookupError!usize {
            if (self.options.servers.len == 0) return error.NoServerConfigured;

            const num_queries: usize = switch (self.options.mode) {
                .ipv4_only, .ipv6_only => 1,
                .ipv4_and_ipv6 => 2,
            };

            var query_pkts: [2]QueryPkt = undefined;
            {
                var qbuf: [512]u8 = undefined;
                const qtype: u16 = if (self.options.mode == .ipv6_only) QTYPE_AAAA else QTYPE_A;
                const id = randomId();
                const len = buildQuery(&qbuf, name, qtype, id) catch return error.InvalidResponse;
                query_pkts[0] = .{ .buf = qbuf, .len = len, .qtype = qtype, .id = id };
            }
            if (num_queries == 2) {
                var qbuf: [512]u8 = undefined;
                const id = randomId();
                const len = buildQuery(&qbuf, name, QTYPE_AAAA, id) catch return error.InvalidResponse;
                query_pkts[1] = .{ .buf = qbuf, .len = len, .qtype = QTYPE_AAAA, .id = id };
            }

            var state = SharedState{
                .next_task = Atomic(usize).init(0),
                .done = Atomic(bool).init(false),
                .mutex = .{},
                .result = .{},
                .servers = self.options.servers,
                .query_pkts = query_pkts[0..num_queries],
                .timeout_ms = self.options.timeout_ms,
                .attempts = self.options.attempts,
            };

            const n_workers: usize = @min(self.options.concurrency, @as(u32, @intCast(self.options.servers.len)));
            if (n_workers == 0) return error.NoServerConfigured;

            const workers = allocator.alloc(Thread, n_workers) catch return error.OutOfMemory;
            defer allocator.free(workers);

            var spawned: usize = 0;
            for (0..n_workers) |_| {
                workers[spawned] = Thread.spawn(self.options.spawn_config, workerFn, .{&state}) catch continue;
                spawned += 1;
            }

            if (spawned == 0) return error.NoServerConfigured;

            for (workers[0..spawned]) |w| w.join();

            state.mutex.lock();
            defer state.mutex.unlock();

            if (!state.result.has_result) return error.Timeout;
            if (state.result.err) |e| return e;

            const count = @min(state.result.count, buf.len);
            for (0..count) |i| buf[i] = state.result.addrs[i];
            return count;
        }

        fn workerFn(state: *SharedState) void {
            while (!state.done.load(.acquire)) {
                const idx = state.next_task.fetchAdd(1, .acq_rel);
                if (idx >= state.servers.len) return;

                const server = state.servers[idx];
                const result: ?WorkerResult = switch (server.protocol) {
                    .udp => udpResolve(server, state),
                    .tcp => tcpResolve(server, state),
                    else => null,
                };

                if (result) |r| {
                    state.mutex.lock();
                    defer state.mutex.unlock();
                    if (!state.done.load(.acquire)) {
                        state.result = r;
                        state.done.store(true, .release);
                    }
                    return;
                }
            }
        }

        fn setRecvTimeout(fd: posix.socket_t, ms: u32) void {
            const tv = posix.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast((@as(u64, ms) % 1000) * 1000),
            };
            const bytes: []const u8 = @as([*]const u8, @ptrCast(&tv))[0..@sizeOf(posix.timeval)];
            posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, bytes) catch {};
        }

        fn udpResolve(server: Server, state: *SharedState) ?WorkerResult {
            const attempts = @max(state.attempts, 1);
            const per_attempt_ms = state.timeout_ms / attempts;

            const fd = posix.socket(
                server.addr.any.family,
                posix.SOCK.DGRAM,
                0,
            ) catch return null;
            defer posix.close(fd);

            setRecvTimeout(fd, per_attempt_ms);

            var result = WorkerResult{};
            var answered: usize = 0;

            var attempt: u32 = 0;
            while (attempt < attempts) : (attempt += 1) {
                if (state.done.load(.acquire)) return null;

                for (state.query_pkts) |qpkt| {
                    var uc = UdpConn.init(fd);
                    _ = uc.writeTo(
                        qpkt.buf[0..qpkt.len],
                        @ptrCast(&server.addr.any),
                        server.addr.getOsSockLen(),
                    ) catch continue;
                }

                var recv_tries: usize = 0;
                while (recv_tries < state.query_pkts.len * 2) : (recv_tries += 1) {
                    if (state.done.load(.acquire)) return null;

                    var recv_buf: [512]u8 = undefined;
                    var uc = UdpConn.init(fd);
                    const rr = uc.readFrom(&recv_buf) catch break;
                    if (rr.bytes_read < 12) continue;

                    const resp_id = readU16(recv_buf[0..2]);
                    const rcode: u4 = @truncate(recv_buf[3]);
                    if (rcode == RCODE_SERVFAIL) break;
                    if (rcode == RCODE_NXDOMAIN) {
                        return WorkerResult{ .has_result = true, .err = error.NameNotFound };
                    }
                    if (rcode == RCODE_REFUSED) {
                        return WorkerResult{ .has_result = true, .err = error.Refused };
                    }
                    if (rcode != RCODE_NOERROR) continue;

                    for (state.query_pkts) |qpkt| {
                        if (qpkt.id != resp_id) continue;
                        const n = parseResponse(recv_buf[0..rr.bytes_read], qpkt.qtype, result.addrs[result.count..]) catch continue;
                        if (n > 0) {
                            result.count += n;
                            answered += 1;
                        }
                        break;
                    }

                    if (answered >= state.query_pkts.len) {
                        result.has_result = true;
                        return result;
                    }
                }
            }
            return null;
        }

        fn tcpResolve(server: Server, state: *SharedState) ?WorkerResult {
            const attempts = @max(state.attempts, 1);
            const per_attempt_ms = state.timeout_ms / attempts;

            var attempt: u32 = 0;
            while (attempt < attempts) : (attempt += 1) {
                if (state.done.load(.acquire)) return null;
                if (tcpAttempt(server, state, per_attempt_ms)) |r| return r;
            }
            return null;
        }

        fn tcpAttempt(server: Server, state: *SharedState, timeout_ms: u32) ?WorkerResult {
            const fd = posix.socket(
                server.addr.any.family,
                posix.SOCK.STREAM,
                0,
            ) catch return null;
            defer posix.close(fd);

            posix.connect(fd, @ptrCast(&server.addr.any), server.addr.getOsSockLen()) catch return null;
            setRecvTimeout(fd, timeout_ms);

            for (state.query_pkts) |qpkt| {
                if (state.done.load(.acquire)) return null;

                var tcp_buf: [514]u8 = undefined;
                tcp_buf[0] = @truncate(qpkt.len >> 8);
                tcp_buf[1] = @truncate(qpkt.len);
                @memcpy(tcp_buf[2..][0..qpkt.len], qpkt.buf[0..qpkt.len]);
                _ = posix.send(fd, tcp_buf[0 .. 2 + qpkt.len], 0) catch return null;
            }

            var result = WorkerResult{};
            var answered: usize = 0;

            for (state.query_pkts) |qpkt| {
                if (state.done.load(.acquire)) return null;

                var len_buf: [2]u8 = undefined;
                const ln = posix.recv(fd, &len_buf, 0) catch return null;
                if (ln < 2) return null;

                const msg_len = readU16(&len_buf);
                if (msg_len < 12 or msg_len > 512) return null;

                var recv_buf: [512]u8 = undefined;
                var total: usize = 0;
                while (total < msg_len) {
                    if (state.done.load(.acquire)) return null;
                    const r = posix.recv(fd, recv_buf[total..msg_len], 0) catch return null;
                    if (r == 0) return null;
                    total += r;
                }

                const rcode: u4 = @truncate(recv_buf[3]);
                if (rcode == RCODE_NXDOMAIN) {
                    return WorkerResult{ .has_result = true, .err = error.NameNotFound };
                }
                if (rcode == RCODE_REFUSED) {
                    return WorkerResult{ .has_result = true, .err = error.Refused };
                }
                if (rcode == RCODE_SERVFAIL) return null;
                if (rcode != RCODE_NOERROR) return null;

                const n = parseResponse(recv_buf[0..msg_len], qpkt.qtype, result.addrs[result.count..]) catch return null;
                if (n > 0) {
                    result.count += n;
                    answered += 1;
                }
            }

            if (answered > 0) {
                result.has_result = true;
                return result;
            }
            return null;
        }

        // --- DNS wire format ---

        pub const QTYPE_A: u16 = 1;
        pub const QTYPE_AAAA: u16 = 28;
        pub const QCLASS_IN: u16 = 1;

        const RCODE_NOERROR: u4 = 0;
        const RCODE_NXDOMAIN: u4 = 3;
        const RCODE_SERVFAIL: u4 = 2;
        const RCODE_REFUSED: u4 = 5;

        const FLAG_RD: u16 = 0x0100;

        pub fn buildQuery(out: *[512]u8, name: []const u8, qtype: u16, id: u16) !usize {
            var pos: usize = 0;

            writeU16(out, &pos, id);
            writeU16(out, &pos, FLAG_RD);
            writeU16(out, &pos, 1);
            writeU16(out, &pos, 0);
            writeU16(out, &pos, 0);
            writeU16(out, &pos, 0);

            var remaining = name;
            while (remaining.len > 0) {
                const dot = mem.indexOfScalar(u8, remaining, '.') orelse remaining.len;
                if (dot == 0 or dot > 63) return error.InvalidResponse;
                if (pos + 1 + dot > 510) return error.InvalidResponse;
                out[pos] = @intCast(dot);
                pos += 1;
                @memcpy(out[pos..][0..dot], remaining[0..dot]);
                pos += dot;
                remaining = if (dot < remaining.len) remaining[dot + 1 ..] else &.{};
            }
            out[pos] = 0;
            pos += 1;

            writeU16(out, &pos, qtype);
            writeU16(out, &pos, QCLASS_IN);

            return pos;
        }

        pub fn parseResponse(pkt: []const u8, qtype: u16, out: []Addr) !usize {
            if (pkt.len < 12) return error.InvalidResponse;

            const ancount = readU16(pkt[6..8]);
            var pos: usize = 12;

            pos = try skipName(pkt, pos);
            if (pos + 4 > pkt.len) return error.InvalidResponse;
            pos += 4;

            var count: usize = 0;
            var i: u16 = 0;
            while (i < ancount) : (i += 1) {
                pos = try skipName(pkt, pos);
                if (pos + 10 > pkt.len) return error.InvalidResponse;

                const rtype = readU16(pkt[pos..][0..2]);
                const rdlength = readU16(pkt[pos + 8 ..][0..2]);
                pos += 10;

                if (pos + rdlength > pkt.len) return error.InvalidResponse;

                if (rtype == qtype and rtype == QTYPE_A and rdlength == 4) {
                    if (count >= out.len) {
                        pos += rdlength;
                        continue;
                    }
                    out[count] = Addr.initIp4(pkt[pos..][0..4].*, 0);
                    count += 1;
                } else if (rtype == qtype and rtype == QTYPE_AAAA and rdlength == 16) {
                    if (count >= out.len) {
                        pos += rdlength;
                        continue;
                    }
                    out[count] = Addr.initIp6(pkt[pos..][0..16].*, 0, 0, 0);
                    count += 1;
                }

                pos += rdlength;
            }

            return count;
        }

        fn skipName(pkt: []const u8, start: usize) !usize {
            var pos = start;
            while (pos < pkt.len) {
                const len = pkt[pos];
                if (len == 0) return pos + 1;
                if (len & 0xC0 == 0xC0) return pos + 2;
                pos += @as(usize, len) + 1;
                if (pos > pkt.len) return error.InvalidResponse;
            }
            return error.InvalidResponse;
        }

        pub fn writeU16(buf: *[512]u8, pos: *usize, val: u16) void {
            buf[pos.*] = @truncate(val >> 8);
            buf[pos.* + 1] = @truncate(val);
            pos.* += 2;
        }

        pub fn readU16(bytes: *const [2]u8) u16 {
            return @as(u16, bytes[0]) << 8 | bytes[1];
        }

        fn randomId() u16 {
            var buf: [2]u8 = undefined;
            lib.crypto.random.bytes(&buf);
            return readU16(&buf);
        }
    };
}

test {
    _ = @import("test_runner/resolver.zig");
}
