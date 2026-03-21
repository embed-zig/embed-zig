//! Resolver — pure-Zig DNS resolver (Go's net.Resolver).
//!
//! Builds and parses DNS wire-format packets (RFC 1035) directly.
//! No libc getaddrinfo, fully portable across embed platforms.
//! Resolver owns its allocator-backed state and any in-flight lookups; call
//! deinit() to wait for outstanding racers/workers to finish cleanup.
//!
//! Strategy (Racer + cleanup):
//!   1. Build query packets (A, AAAA depending on mode)
//!   2. Create one Racer per lookup
//!   3. Spawn one Racer task per configured server
//!   4. Only successful address results are published through sync.Racer
//!   5. Main thread returns as soon as Racer gets the first result
//!   6. Negative DNS replies are recorded and returned only if all servers fail
//!   7. Detached cleanup waits for lagging workers and frees lookup state
//!   8. deinit() waits for all outstanding lookups to finish cleanup

const dialer = @import("Dialer.zig");
const context_mod = @import("context");
const io = @import("io");
const sync = @import("sync");

pub fn Resolver(comptime lib: type) type {
    const posix = lib.posix;
    const Addr = lib.net.Address;
    const Dialer = dialer.Dialer(lib);
    const mem = lib.mem;
    const Allocator = mem.Allocator;
    const Thread = lib.Thread;
    return struct {
        allocator: Allocator,
        options: Options,
        mutex: Thread.Mutex = .{},
        cond: Thread.Condition = .{},
        deiniting: bool = false,
        active_lookups: usize = 0,

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
            mode: QueryMode = .ipv4_only,
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
            Closed,
            OutOfMemory,
        } || posix.SocketError || posix.SendToError || posix.RecvFromError ||
            posix.ConnectError || posix.SendError || posix.SetSockOptError ||
            Thread.SpawnError;

        pub fn init(allocator: Allocator, options: Options) Allocator.Error!Self {
            const servers = try allocator.dupe(Server, options.servers);
            var owned_options = options;
            owned_options.servers = servers;
            return .{
                .allocator = allocator,
                .options = owned_options,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            self.deiniting = true;
            while (self.active_lookups != 0) {
                self.cond.wait(&self.mutex);
            }
            self.mutex.unlock();

            self.allocator.free(self.options.servers);
            self.* = undefined;
        }

        pub fn wait(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.active_lookups != 0) {
                self.cond.wait(&self.mutex);
            }
        }

        const MAX_ADDRS = 16;

        const WorkerResult = struct {
            addrs: [MAX_ADDRS]Addr = undefined,
            count: usize = 0,
            err: ?LookupError = null,
            has_result: bool = false,
        };

        const WorkerRacer = sync.Racer(lib, WorkerResult);

        const LookupJob = struct {
            resolver: *Self,
            racer: WorkerRacer,
            query_pkts: [2]QueryPkt,
            query_count: usize,
            failure_mutex: Thread.Mutex = .{},
            saw_name_not_found: bool = false,
            saw_refused: bool = false,

            fn queryPkts(self: *const LookupJob) []const QueryPkt {
                return self.query_pkts[0..self.query_count];
            }

            fn queryIndexById(self: *const LookupJob, id: u16) ?usize {
                for (self.queryPkts(), 0..) |qpkt, idx| {
                    if (qpkt.id == id) return idx;
                }
                return null;
            }

            fn recordFailure(self: *LookupJob, err: LookupError) void {
                self.failure_mutex.lock();
                defer self.failure_mutex.unlock();

                switch (err) {
                    error.NameNotFound => self.saw_name_not_found = true,
                    error.Refused => self.saw_refused = true,
                    else => {},
                }
            }

            fn finalError(self: *LookupJob) LookupError {
                self.failure_mutex.lock();
                defer self.failure_mutex.unlock();

                if (self.saw_name_not_found) return error.NameNotFound;
                if (self.saw_refused) return error.Refused;
                return error.Timeout;
            }
        };

        const QueryPkt = struct {
            buf: [512]u8,
            len: usize,
            qtype: u16,
            id: u16,
        };

        /// Public resolver calls return `anyerror` so they can transparently
        /// propagate arbitrary causes injected via `context.cancelWithCause(...)`.
        pub fn lookupHost(self: *Self, name: []const u8, buf: []Addr) anyerror!usize {
            const Context = context_mod.Make(lib);
            var context_api = try Context.init(self.allocator);
            defer context_api.deinit();
            return self.lookupHostContext(context_api.background(), name, buf);
        }

        pub fn lookupHostContext(self: *Self, ctx: context_mod.Context, name: []const u8, buf: []Addr) anyerror!usize {
            try self.beginLookup();
            var needs_finish_lookup = true;
            errdefer if (needs_finish_lookup) self.finishLookup();

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
                var id = randomId();
                while (id == query_pkts[0].id) : (id = randomId()) {}
                const len = buildQuery(&qbuf, name, QTYPE_AAAA, id) catch return error.InvalidResponse;
                query_pkts[1] = .{ .buf = qbuf, .len = len, .qtype = QTYPE_AAAA, .id = id };
            }

            const job = self.allocator.create(LookupJob) catch return error.OutOfMemory;
            var owns_job = false;
            var destroy_raw_job_on_error = true;
            errdefer if (destroy_raw_job_on_error) self.allocator.destroy(job);

            job.* = .{
                .resolver = self,
                .racer = undefined,
                .query_pkts = undefined,
                .query_count = num_queries,
            };
            @memcpy(job.query_pkts[0..num_queries], query_pkts[0..num_queries]);
            job.racer = WorkerRacer.init(self.allocator) catch return error.OutOfMemory;
            destroy_raw_job_on_error = false;

            owns_job = true;
            defer if (owns_job) self.destroyLookupJob(job);
            needs_finish_lookup = false;

            var spawned: usize = 0;
            var spawn_err: ?Thread.SpawnError = null;
            // TODO: Partial spawn failure currently degrades to a best-effort
            // query using only the server tasks that started successfully.
            for (self.options.servers) |server| {
                job.racer.spawn(self.options.spawn_config, serverTask, .{ job, server }) catch |err| {
                    if (spawn_err == null) spawn_err = err;
                    continue;
                };
                spawned += 1;
            }

            if (spawned == 0) return spawn_err orelse error.NoServerConfigured;

            const race_result = job.racer.raceContext(ctx) catch |err| {
                if (self.beginCleanup(job)) {
                    owns_job = false;
                } else {
                    job.racer.wait();
                }
                return err;
            };

            const result = switch (race_result) {
                .winner => |winner| winner,
                .exhausted => return job.finalError(),
            };

            if (self.beginCleanup(job)) {
                owns_job = false;
            } else {
                job.racer.wait();
            }

            if (!result.has_result) return error.Timeout;
            if (result.err) |e| return e;

            const count = @min(result.count, buf.len);
            for (0..count) |i| buf[i] = result.addrs[i];
            return count;
        }

        fn serverTask(ctx: WorkerRacer.State, job: *LookupJob, server: Server) void {
            const result: ?WorkerResult = switch (server.protocol) {
                .udp => udpResolve(ctx, server, job),
                .tcp => tcpResolve(ctx, server, job),
                else => null,
            };

            if (result) |r| {
                if (r.err) |err| {
                    job.recordFailure(err);
                } else if (r.has_result) {
                    _ = ctx.success(r);
                }
            }
        }

        fn udpResolve(ctx: WorkerRacer.State, server: Server, job: *LookupJob) ?WorkerResult {
            const attempts = @max(job.resolver.options.attempts, 1);
            const per_attempt_ms = job.resolver.options.timeout_ms / attempts;

            const d = Dialer.init(job.resolver.allocator, .{});
            var c = d.dial(.udp, server.addr) catch return null;
            defer c.deinit();

            c.setReadTimeout(per_attempt_ms);

            var result = WorkerResult{};
            var replied = [2]bool{ false, false };
            var replied_count: usize = 0;

            var attempt: u32 = 0;
            while (attempt < attempts) : (attempt += 1) {
                if (ctx.done()) return null;
                const outstanding = job.queryPkts().len - replied_count;
                if (outstanding == 0) break;
                var handled = replied;
                var handled_count = replied_count;

                for (job.queryPkts(), 0..) |qpkt, idx| {
                    if (replied[idx]) continue;
                    // Each DNS UDP query is sent as a single datagram, so use one
                    // write per packet rather than stream-style retry semantics.
                    _ = c.write(qpkt.buf[0..qpkt.len]) catch continue;
                }

                var recv_tries: usize = 0;
                while (recv_tries < outstanding * 2) : (recv_tries += 1) {
                    if (ctx.done()) return null;
                    if (handled_count >= job.queryPkts().len) break;

                    var recv_buf: [512]u8 = undefined;
                    const recv_n = c.read(&recv_buf) catch break;
                    if (recv_n < 12) continue;

                    const resp_id = readU16(recv_buf[0..2]);
                    const idx = job.queryIndexById(resp_id) orelse continue;
                    if (handled[idx]) continue;

                    const qpkt = job.queryPkts()[idx];
                    const rcode: u4 = @truncate(recv_buf[3]);
                    if (rcode == RCODE_SERVFAIL) {
                        handled[idx] = true;
                        handled_count += 1;
                        if (handled_count >= job.queryPkts().len) break;
                        continue;
                    }
                    if (rcode == RCODE_NXDOMAIN) {
                        return WorkerResult{ .has_result = true, .err = error.NameNotFound };
                    }
                    if (rcode == RCODE_REFUSED) {
                        return WorkerResult{ .has_result = true, .err = error.Refused };
                    }
                    if (rcode != RCODE_NOERROR) continue;

                    const n = parseResponse(recv_buf[0..recv_n], qpkt.qtype, result.addrs[result.count..]) catch continue;
                    replied[idx] = true;
                    replied_count += 1;
                    handled[idx] = true;
                    handled_count += 1;
                    if (n > 0) {
                        result.count += n;
                    }

                    if (handled_count >= job.queryPkts().len) {
                        if (result.count > 0) {
                            result.has_result = true;
                            return result;
                        }
                        break;
                    }
                }
            }
            if (result.count > 0) {
                result.has_result = true;
                return result;
            }
            if (replied_count >= job.queryPkts().len) {
                return WorkerResult{ .has_result = true, .err = error.NameNotFound };
            }
            return null;
        }

        fn tcpResolve(ctx: WorkerRacer.State, server: Server, job: *LookupJob) ?WorkerResult {
            const attempts = @max(job.resolver.options.attempts, 1);
            const per_attempt_ms = job.resolver.options.timeout_ms / attempts;

            var attempt: u32 = 0;
            while (attempt < attempts) : (attempt += 1) {
                if (ctx.done()) return null;
                if (tcpAttempt(ctx, server, job, per_attempt_ms)) |r| return r;
            }
            return null;
        }

        fn tcpAttempt(ctx: WorkerRacer.State, server: Server, job: *LookupJob, timeout_ms: u32) ?WorkerResult {
            const d = Dialer.init(job.resolver.allocator, .{});
            var c = d.dial(.tcp, server.addr) catch return null;
            defer c.deinit();

            c.setReadTimeout(timeout_ms);
            c.setWriteTimeout(timeout_ms);

            for (job.queryPkts()) |qpkt| {
                if (ctx.done()) return null;

                var tcp_buf: [514]u8 = undefined;
                tcp_buf[0] = @truncate(qpkt.len >> 8);
                tcp_buf[1] = @truncate(qpkt.len);
                @memcpy(tcp_buf[2..][0..qpkt.len], qpkt.buf[0..qpkt.len]);
                io.writeAll(@TypeOf(c), &c, tcp_buf[0 .. 2 + qpkt.len]) catch return null;
            }

            var result = WorkerResult{};
            var replied = [2]bool{ false, false };
            var replied_count: usize = 0;
            var handled = [2]bool{ false, false };
            var handled_count: usize = 0;

            while (handled_count < job.queryPkts().len) {
                if (ctx.done()) return null;

                var len_buf: [2]u8 = undefined;
                io.readFull(@TypeOf(c), &c, &len_buf) catch return null;

                const msg_len = readU16(&len_buf);
                if (msg_len < 12 or msg_len > 512) return null;

                var recv_buf: [512]u8 = undefined;
                io.readFull(@TypeOf(c), &c, recv_buf[0..msg_len]) catch return null;

                const resp_id = readU16(recv_buf[0..2]);
                const idx = job.queryIndexById(resp_id) orelse continue;
                if (handled[idx]) continue;

                const qpkt = job.queryPkts()[idx];
                const rcode: u4 = @truncate(recv_buf[3]);
                if (rcode == RCODE_NXDOMAIN) {
                    return WorkerResult{ .has_result = true, .err = error.NameNotFound };
                }
                if (rcode == RCODE_REFUSED) {
                    return WorkerResult{ .has_result = true, .err = error.Refused };
                }
                if (rcode == RCODE_SERVFAIL) {
                    handled[idx] = true;
                    handled_count += 1;
                    continue;
                }
                if (rcode != RCODE_NOERROR) return null;

                const n = parseResponse(recv_buf[0..msg_len], qpkt.qtype, result.addrs[result.count..]) catch return null;
                replied[idx] = true;
                replied_count += 1;
                handled[idx] = true;
                handled_count += 1;
                if (n > 0) {
                    result.count += n;
                }
            }

            if (result.count > 0) {
                result.has_result = true;
                return result;
            }
            if (replied_count >= job.queryPkts().len) {
                return WorkerResult{ .has_result = true, .err = error.NameNotFound };
            }
            return null;
        }

        fn beginLookup(self: *Self) error{Closed}!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.deiniting) return error.Closed;
            self.active_lookups += 1;
        }

        fn finishLookup(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            @import("std").debug.assert(self.active_lookups > 0);
            self.active_lookups -= 1;
            if (self.active_lookups == 0) self.cond.broadcast();
        }

        fn beginCleanup(self: *Self, job: *LookupJob) bool {
            var t = Thread.spawn(self.cleanupSpawnConfig(), cleanupFn, .{job}) catch return false;
            t.detach();
            return true;
        }

        fn cleanupFn(job: *LookupJob) void {
            job.resolver.destroyLookupJob(job);
        }

        fn destroyLookupJob(self: *Self, job: *LookupJob) void {
            job.racer.deinit();
            self.allocator.destroy(job);
            self.finishLookup();
        }

        fn cleanupSpawnConfig(self: *Self) Thread.SpawnConfig {
            var config = self.options.spawn_config;
            if (@hasField(Thread.SpawnConfig, "allocator")) {
                if (config.allocator == null) {
                    config.allocator = self.allocator;
                }
            }
            return config;
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

        fn buildQuery(out: *[512]u8, name: []const u8, qtype: u16, id: u16) !usize {
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

        fn parseResponse(pkt: []const u8, qtype: u16, out: []Addr) !usize {
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

        fn writeU16(buf: *[512]u8, pos: *usize, val: u16) void {
            buf[pos.*] = @truncate(val >> 8);
            buf[pos.* + 1] = @truncate(val);
            pos.* += 2;
        }

        fn readU16(bytes: *const [2]u8) u16 {
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
    _ = @import("test_runner/resolver_fake.zig");
    _ = @import("test_runner/resolver_ali_dns.zig");
}
