//! Resolver — pure-Zig DNS resolver (Go's net.Resolver).
//!
//! Builds and parses DNS wire-format packets (RFC 1035) directly.
//! No libc getaddrinfo, fully portable across embed platforms.
//!
//! Strategy (mirrors Zig std's resMSendRc):
//!   1. Build query packets (A, AAAA)
//!   2. Open UDP sockets (one per address family)
//!   3. Fan-out: send each query to ALL configured servers
//!   4. Poll for responses; match by query ID
//!   5. On SERVFAIL, retry up to `attempts` times
//!   6. Retry unanswered queries at `timeout / attempts` intervals
//!   7. Extract A/AAAA records from responses into caller buffer

const udp_conn = @import("UdpConn.zig");

pub fn Resolver(comptime lib: type) type {
    const posix = lib.posix;
    const Addr = lib.net.Address;
    const UdpConn = udp_conn.UdpConn(lib);
    const mem = lib.mem;

    return struct {
        options: Options,

        const Self = @This();

        pub const Protocol = enum(u3) {
            udp = 0,
            tcp = 1,
            tls = 2,
            doh = 3, // DNS-over-HTTPS (not yet implemented)
        };

        pub const ProtocolSet = lib.EnumSet(Protocol);

        pub const Server = struct {
            addr: Addr,
            protocols: ProtocolSet = ProtocolSet.initMany(&.{ .udp, .tcp }),
        };

        pub const Options = struct {
            servers: []const Server = &.{
                .{ .addr = Addr.initIp4(.{ 8, 8, 8, 8 }, 53) },
                .{ .addr = Addr.initIp4(.{ 1, 1, 1, 1 }, 53) },
            },
            timeout_ms: u32 = 5000,
            attempts: u32 = 2,
            mode: QueryMode = .ipv4_and_ipv6,
        };

        pub const QueryMode = enum {
            ipv4_only,
            ipv6_only,
            ipv4_and_ipv6,
        };

        pub const LookupError = error{
            NameNotFound,
            ServerFailure,
            Refused,
            Timeout,
            InvalidResponse,
            NoServerConfigured,
            BufferTooSmall,
        } || posix.SocketError || posix.SendToError || posix.RecvFromError || posix.PollError;

        pub fn init(options: Options) Self {
            return .{ .options = options };
        }

        /// Resolve hostname to IP addresses.
        /// Returns the number of addresses written to `buf`.
        pub fn lookupHost(self: Self, name: []const u8, buf: []Addr) LookupError!usize {
            if (self.options.servers.len == 0) return error.NoServerConfigured;

            const num_queries: usize = switch (self.options.mode) {
                .ipv4_only, .ipv6_only => 1,
                .ipv4_and_ipv6 => 2,
            };

            var queries: [2]Query = undefined;
            var query_bufs: [2][512]u8 = undefined;

            queries[0] = .{
                .qtype = if (self.options.mode == .ipv6_only) QTYPE_AAAA else QTYPE_A,
                .id = randomId(),
                .answered = false,
                .rcode = 0,
                .answer_len = 0,
            };
            queries[0].pkt_len = buildQuery(&query_bufs[0], name, queries[0].qtype, queries[0].id) catch
                return error.InvalidResponse;

            if (num_queries == 2) {
                queries[1] = .{
                    .qtype = QTYPE_AAAA,
                    .id = randomId(),
                    .answered = false,
                    .rcode = 0,
                    .answer_len = 0,
                };
                queries[1].pkt_len = buildQuery(&query_bufs[1], name, queries[1].qtype, queries[1].id) catch
                    return error.InvalidResponse;
            }

            const has_v4 = self.hasUdpFamily(posix.AF.INET);
            const has_v6 = self.hasUdpFamily(posix.AF.INET6);
            if (!has_v4 and !has_v6) return error.NoServerConfigured;

            var fd4: ?posix.socket_t = null;
            var fd6: ?posix.socket_t = null;
            defer {
                if (fd4) |f| posix.close(f);
                if (fd6) |f| posix.close(f);
            }
            if (has_v4) fd4 = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            if (has_v6) fd6 = try posix.socket(posix.AF.INET6, posix.SOCK.DGRAM, 0);

            const interval_ms: i64 = @intCast(self.options.timeout_ms / self.options.attempts);
            var retry: u32 = 0;

            while (retry < self.options.attempts) : (retry += 1) {
                for (queries[0..num_queries]) |*q| {
                    if (q.answered) continue;
                    const pkt = query_bufs[q.slotIndex(queries[0..num_queries])][0..q.pkt_len];
                    for (self.options.servers) |server| {
                        if (!server.protocols.contains(.udp)) continue;
                        const fd = if (server.addr.any.family == posix.AF.INET6) fd6 else fd4;
                        if (fd) |f| {
                            var uc = UdpConn.init(f);
                            _ = uc.writeTo(pkt, @ptrCast(&server.addr.any), server.addr.getOsSockLen()) catch continue;
                        }
                    }
                }

                const attempt_start = lib.time.milliTimestamp();
                const attempt_deadline = attempt_start + interval_ms;

                while (true) {
                    const now = lib.time.milliTimestamp();
                    const remaining_ms = attempt_deadline - now;
                    if (remaining_ms <= 0) break;

                    var nfds: usize = 0;
                    var pfds: [2]posix.pollfd = undefined;
                    if (fd4) |f| {
                        pfds[nfds] = .{ .fd = f, .events = posix.POLL.IN, .revents = 0 };
                        nfds += 1;
                    }
                    if (fd6) |f| {
                        pfds[nfds] = .{ .fd = f, .events = posix.POLL.IN, .revents = 0 };
                        nfds += 1;
                    }

                    const ready = posix.poll(pfds[0..nfds], @intCast(remaining_ms)) catch break;
                    if (ready == 0) break;

                    for (pfds[0..nfds]) |pfd| {
                        if (pfd.revents & posix.POLL.IN == 0) continue;
                        var uc = UdpConn.init(pfd.fd);
                        var recv_buf: [512]u8 = undefined;
                        const result = uc.readFrom(&recv_buf) catch continue;
                        if (result.bytes_read < 12) continue;
                        const n = result.bytes_read;

                        const resp_id = readU16(recv_buf[0..2]);
                        const rcode: u4 = @truncate(recv_buf[3]);

                        for (queries[0..num_queries]) |*q| {
                            if (q.id == resp_id and !q.answered) {
                                if (rcode == RCODE_SERVFAIL) {
                                    q.id = randomId();
                                    q.pkt_len = buildQuery(
                                        &query_bufs[q.slotIndex(queries[0..num_queries])],
                                        name,
                                        q.qtype,
                                        q.id,
                                    ) catch continue;
                                    break;
                                }
                                q.answered = true;
                                q.rcode = rcode;
                                q.answer_len = n;
                                @memcpy(q.answer_buf[0..n], recv_buf[0..n]);
                                break;
                            }
                        }
                    }

                    if (allAnswered(queries[0..num_queries])) break;
                }

                if (allAnswered(queries[0..num_queries])) break;
            }

            var count: usize = 0;
            for (queries[0..num_queries]) |q| {
                if (!q.answered) continue;
                if (q.rcode == RCODE_NXDOMAIN) return error.NameNotFound;
                if (q.rcode == RCODE_SERVFAIL) return error.ServerFailure;
                if (q.rcode == RCODE_REFUSED) return error.Refused;
                if (q.rcode != RCODE_NOERROR) return error.InvalidResponse;

                count += parseResponse(q.answer_buf[0..q.answer_len], q.qtype, buf[count..]) catch
                    return error.InvalidResponse;
            }

            if (count == 0) {
                var any_answered = false;
                for (queries[0..num_queries]) |q| {
                    if (q.answered) {
                        any_answered = true;
                        break;
                    }
                }
                if (!any_answered) return error.Timeout;
            }

            return count;
        }

        fn allAnswered(queries: []const Query) bool {
            for (queries) |q| {
                if (!q.answered) return false;
            }
            return true;
        }

        fn hasUdpFamily(self: Self, family: u32) bool {
            for (self.options.servers) |s| {
                if (s.protocols.contains(.udp) and s.addr.any.family == family) return true;
            }
            return false;
        }

        const Query = struct {
            qtype: u16,
            id: u16,
            pkt_len: usize = 0,
            answered: bool,
            rcode: u4 = 0,
            answer_buf: [512]u8 = undefined,
            answer_len: usize = 0,

            fn slotIndex(self: *const Query, all: []const Query) usize {
                return (@intFromPtr(self) - @intFromPtr(all.ptr)) / @sizeOf(Query);
            }
        };

        // --- DNS wire format constants ---

        pub const QTYPE_A: u16 = 1;
        pub const QTYPE_AAAA: u16 = 28;
        pub const QCLASS_IN: u16 = 1;

        const RCODE_NOERROR: u4 = 0;
        const RCODE_NXDOMAIN: u4 = 3;
        const RCODE_SERVFAIL: u4 = 2;
        const RCODE_REFUSED: u4 = 5;

        const FLAG_RD: u16 = 0x0100; // Recursion Desired

        pub fn buildQuery(out: *[512]u8, name: []const u8, qtype: u16, id: u16) !usize {
            var pos: usize = 0;

            writeU16(out, &pos, id);
            writeU16(out, &pos, FLAG_RD);
            writeU16(out, &pos, 1); // QDCOUNT
            writeU16(out, &pos, 0); // ANCOUNT
            writeU16(out, &pos, 0); // NSCOUNT
            writeU16(out, &pos, 0); // ARCOUNT

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
