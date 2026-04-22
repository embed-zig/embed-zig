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

const std = @import("std");
const Conn = @import("Conn.zig");
const dialer = @import("Dialer.zig");
const http_mod = @import("http.zig");
const netip = @import("netip.zig");
const tls_mod = @import("tls.zig");
const context_mod = @import("context");
const sync = @import("sync");
const testing_api = @import("testing");

pub fn Resolver(comptime lib: type) type {
    const posix = lib.posix;
    const Addr = netip.Addr;
    const AddrPort = netip.AddrPort;
    const ContextApi = context_mod.make(lib);
    const Dialer = dialer.Dialer(lib);
    const Http = http_mod.make(lib);
    const Tls = tls_mod.make(lib);
    const Atomic = lib.atomic.Value;
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

        pub const TlsConfig = Tls.Config;

        pub const Server = struct {
            addr: AddrPort,
            protocol: Protocol = .udp,
            tls_config: ?TlsConfig = null,
            doh_path: []const u8 = "",

            pub fn init(comptime ip: []const u8, comptime protocol: Protocol) Server {
                const port: u16 = comptime switch (protocol) {
                    .udp, .tcp => 53,
                    .tls => 853,
                    .doh => 443,
                };
                return .{
                    .addr = AddrPort.init(comptime Addr.parse(ip) catch unreachable, port),
                    .protocol = protocol,
                    .tls_config = comptime switch (protocol) {
                        .tls, .doh => if (tlsServerNameForIp(ip)) |server_name|
                            TlsConfig{ .server_name = server_name }
                        else
                            null,
                        else => null,
                    },
                    .doh_path = comptime switch (protocol) {
                        .doh => "/dns-query",
                        else => "",
                    },
                };
            }

            pub fn initTls(comptime ip: []const u8, comptime server_name: []const u8) Server {
                return .{
                    .addr = AddrPort.init(comptime Addr.parse(ip) catch unreachable, 853),
                    .protocol = .tls,
                    .tls_config = .{ .server_name = server_name },
                };
            }

            pub fn initDoh(comptime ip: []const u8, comptime server_name: []const u8) Server {
                return initDohPath(ip, server_name, "/dns-query");
            }

            pub fn initDohPath(comptime ip: []const u8, comptime server_name: []const u8, comptime path: []const u8) Server {
                return .{
                    .addr = AddrPort.init(comptime Addr.parse(ip) catch unreachable, 443),
                    .protocol = .doh,
                    .tls_config = .{ .server_name = server_name },
                    .doh_path = path,
                };
            }
        };

        pub const dns = struct {
            pub const ali = struct {
                pub const v4_1 = "223.5.5.5";
                pub const v4_2 = "223.6.6.6";
                pub const v6_1 = "2400:3200::1";
                pub const v6_2 = "2400:3200:baba::1";
                pub const server_name = "dns.alidns.com";
            };
            pub const google = struct {
                pub const v4_1 = "8.8.8.8";
                pub const v4_2 = "8.8.4.4";
                pub const v6_1 = "2001:4860:4860::8888";
                pub const v6_2 = "2001:4860:4860::8844";
                pub const server_name = "dns.google";
            };
            pub const cloudflare = struct {
                pub const v4_1 = "1.1.1.1";
                pub const v4_2 = "1.0.0.1";
                pub const v6_1 = "2606:4700:4700::1111";
                pub const v6_2 = "2606:4700:4700::1001";
                pub const server_name = "cloudflare-dns.com";
            };
            pub const quad9 = struct {
                pub const v4_1 = "9.9.9.9";
                pub const v4_2 = "149.112.112.112";
                pub const server_name = "dns.quad9.net";
            };
        };

        fn tlsServerNameForIp(comptime ip: []const u8) ?[]const u8 {
            if (mem.eql(u8, ip, dns.ali.v4_1) or mem.eql(u8, ip, dns.ali.v4_2) or mem.eql(u8, ip, dns.ali.v6_1) or mem.eql(u8, ip, dns.ali.v6_2)) {
                return dns.ali.server_name;
            }
            if (mem.eql(u8, ip, dns.google.v4_1) or mem.eql(u8, ip, dns.google.v4_2) or mem.eql(u8, ip, dns.google.v6_1) or mem.eql(u8, ip, dns.google.v6_2)) {
                return dns.google.server_name;
            }
            if (mem.eql(u8, ip, dns.cloudflare.v4_1) or mem.eql(u8, ip, dns.cloudflare.v4_2) or mem.eql(u8, ip, dns.cloudflare.v6_1) or mem.eql(u8, ip, dns.cloudflare.v6_2)) {
                return dns.cloudflare.server_name;
            }
            if (mem.eql(u8, ip, dns.quad9.v4_1) or mem.eql(u8, ip, dns.quad9.v4_2)) {
                return dns.quad9.server_name;
            }
            return null;
        }

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
            NoData,
            Refused,
            Timeout,
            InvalidResponse,
            InvalidTlsConfig,
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
        const worker_io_quantum_ms: i64 = 50;
        const worker_attempt_cancel_poll_ns: u64 = 1 * lib.time.ns_per_ms;

        const LookupJob = struct {
            resolver: *Self,
            racer: WorkerRacer,
            query_pkts: [2]QueryPkt,
            query_count: usize,
            failure_mutex: Thread.Mutex = .{},
            saw_name_not_found: bool = false,
            saw_no_data: bool = false,
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
                    error.NoData => self.saw_no_data = true,
                    error.Refused => self.saw_refused = true,
                    else => {},
                }
            }

            fn finalError(self: *LookupJob) LookupError {
                self.failure_mutex.lock();
                defer self.failure_mutex.unlock();

                if (self.saw_name_not_found) return error.NameNotFound;
                if (self.saw_no_data) return error.NoData;
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

        const WorkerAttemptScope = struct {
            state: WorkerRacer.State,
            context_api: ContextApi,
            deadline_ctx: context_mod.Context,
            ctx: context_mod.Context,
            stop_requested: Atomic(bool) = Atomic(bool).init(false),
            watcher: ?Thread = null,

            fn init(allocator: Allocator, state: WorkerRacer.State, timeout_ms: u32) Allocator.Error!@This() {
                var context_api = try ContextApi.init(allocator);
                errdefer context_api.deinit();

                var deadline_ctx = try context_api.withDeadline(
                    context_api.background(),
                    lib.time.nanoTimestamp() + @as(i128, timeout_ms) * lib.time.ns_per_ms,
                );
                errdefer deadline_ctx.deinit();

                var ctx = try context_api.withCancel(deadline_ctx);
                errdefer ctx.deinit();

                return .{
                    .state = state,
                    .context_api = context_api,
                    .deadline_ctx = deadline_ctx,
                    .ctx = ctx,
                };
            }

            fn start(self: *@This(), spawn_config: Thread.SpawnConfig) Thread.SpawnError!void {
                self.watcher = try Thread.spawn(spawn_config, watchRacerDone, .{self});
            }

            fn deinit(self: *@This()) void {
                self.stop_requested.store(true, .release);
                if (self.watcher) |t| t.join();
                self.ctx.deinit();
                self.deadline_ctx.deinit();
                self.context_api.deinit();
                self.* = undefined;
            }

            fn context(self: *@This()) context_mod.Context {
                return self.ctx;
            }

            fn watchRacerDone(self: *@This()) void {
                while (true) {
                    if (self.stop_requested.load(.acquire)) return;
                    if (self.state.done()) {
                        self.ctx.cancel();
                        return;
                    }
                    Thread.sleep(worker_attempt_cancel_poll_ns);
                }
            }
        };

        /// Public resolver calls return `anyerror` so they can transparently
        /// propagate arbitrary causes injected via `context.cancelWithCause(...)`.
        pub fn lookupHost(self: *Self, name: []const u8, buf: []Addr) anyerror!usize {
            const Context = context_mod.make(lib);
            var context_api = try Context.init(self.allocator);
            defer context_api.deinit();
            return self.lookupHostContext(context_api.background(), name, buf);
        }

        pub fn lookupHostContext(self: *Self, ctx: context_mod.Context, name: []const u8, buf: []Addr) anyerror!usize {
            try self.beginLookup();
            var needs_finish_lookup = true;
            errdefer if (needs_finish_lookup) self.finishLookup();

            if (self.options.servers.len == 0) return error.NoServerConfigured;
            for (self.options.servers) |server| try validateServer(server);

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
                job.racer.cancel();
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
                .tls => tlsResolve(ctx, server, job),
                .doh => dohResolve(ctx, server, job),
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
                return WorkerResult{ .has_result = true, .err = error.NoData };
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
            var attempt_ctx = WorkerAttemptScope.init(job.resolver.allocator, ctx, timeout_ms) catch |err| {
                return WorkerResult{ .has_result = true, .err = err };
            };
            defer attempt_ctx.deinit();
            attempt_ctx.start(job.resolver.options.spawn_config) catch |err| {
                return WorkerResult{ .has_result = true, .err = err };
            };
            var c = d.dialContext(attempt_ctx.context(), .tcp, server.addr) catch return null;
            defer c.deinit();

            return streamAttempt(ctx, c, job, timeout_ms);
        }

        fn tlsResolve(ctx: WorkerRacer.State, server: Server, job: *LookupJob) ?WorkerResult {
            const attempts = @max(job.resolver.options.attempts, 1);
            const per_attempt_ms = job.resolver.options.timeout_ms / attempts;

            var attempt: u32 = 0;
            while (attempt < attempts) : (attempt += 1) {
                if (ctx.done()) return null;
                if (tlsAttempt(ctx, server, job, per_attempt_ms)) |r| return r;
            }
            return null;
        }

        fn tlsAttempt(ctx: WorkerRacer.State, server: Server, job: *LookupJob, timeout_ms: u32) ?WorkerResult {
            const tls_config = server.tls_config orelse return null;
            const net_dialer = Dialer.init(job.resolver.allocator, .{});
            const tls_dialer = Tls.Dialer.init(net_dialer, tls_config);
            var attempt_ctx = WorkerAttemptScope.init(job.resolver.allocator, ctx, timeout_ms) catch |err| {
                return WorkerResult{ .has_result = true, .err = err };
            };
            defer attempt_ctx.deinit();
            attempt_ctx.start(job.resolver.options.spawn_config) catch |err| {
                return WorkerResult{ .has_result = true, .err = err };
            };
            var c = tls_dialer.dialContext(attempt_ctx.context(), .tcp, server.addr) catch return null;
            defer c.deinit();

            c.setReadTimeout(timeout_ms);
            c.setWriteTimeout(timeout_ms);

            const tls_conn = c.as(Tls.Conn) catch return null;
            if (ctx.done()) return null;
            tls_conn.handshake() catch return null;

            return streamAttempt(ctx, c, job, timeout_ms);
        }

        fn dohResolve(ctx: WorkerRacer.State, server: Server, job: *LookupJob) ?WorkerResult {
            const attempts = @max(job.resolver.options.attempts, 1);
            const per_attempt_ms = job.resolver.options.timeout_ms / attempts;

            var attempt: u32 = 0;
            while (attempt < attempts) : (attempt += 1) {
                if (ctx.done()) return null;
                if (dohAttempt(ctx, server, job, per_attempt_ms)) |r| return r;
            }
            return null;
        }

        fn dohAttempt(ctx: WorkerRacer.State, server: Server, job: *LookupJob, timeout_ms: u32) ?WorkerResult {
            var result = WorkerResult{};
            var replied = [2]bool{ false, false };
            var replied_count: usize = 0;
            var handled = [2]bool{ false, false };
            var handled_count: usize = 0;

            for (job.queryPkts(), 0..) |qpkt, idx| {
                if (ctx.done()) return null;

                var recv_buf: [2048]u8 = undefined;
                const recv_n = (dohExchange(
                    ctx,
                    server,
                    qpkt,
                    job.resolver.allocator,
                    job.resolver.options.spawn_config,
                    timeout_ms,
                    &recv_buf,
                ) catch |err| return WorkerResult{ .has_result = true, .err = err }) orelse return null;
                if (recv_n < 12) return null;
                if (readU16(recv_buf[0..2]) != qpkt.id) return null;

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

                const n = parseResponse(recv_buf[0..recv_n], qpkt.qtype, result.addrs[result.count..]) catch return null;
                replied[idx] = true;
                replied_count += 1;
                handled[idx] = true;
                handled_count += 1;
                if (n > 0) result.count += n;
            }

            if (result.count > 0) {
                result.has_result = true;
                return result;
            }
            if (replied_count >= job.queryPkts().len and handled_count >= job.queryPkts().len) {
                return WorkerResult{ .has_result = true, .err = error.NoData };
            }
            return null;
        }

        fn dohExchange(
            ctx: WorkerRacer.State,
            server: Server,
            qpkt: QueryPkt,
            allocator: Allocator,
            spawn_config: Thread.SpawnConfig,
            timeout_ms: u32,
            out: []u8,
        ) LookupError!?usize {
            const tls_config = server.tls_config orelse return null;
            var attempt_ctx = try WorkerAttemptScope.init(allocator, ctx, timeout_ms);
            defer attempt_ctx.deinit();
            try attempt_ctx.start(spawn_config);
            // DoH here is an internal one-shot DNS wire exchange, so keep it on a
            // short-lived Transport rather than layering in Client redirect/policy
            // behavior or extra shared client state.
            var transport = Http.Transport.init(allocator, .{
                .resolver = .{ .servers = &.{} },
                .spawn_config = spawn_config,
                .tls_client_config = tls_config,
                .disable_keep_alives = true,
                .max_idle_conns = 0,
                .tls_handshake_timeout_ms = timeout_ms,
                .response_header_timeout_ms = timeout_ms,
            }) catch return null;
            defer transport.deinit();

            var url_buf: [256]u8 = undefined;
            const raw_url = formatDohUrl(server, &url_buf) catch return null;
            var req = Http.Request.init(allocator, "POST", raw_url) catch return null;
            defer req.deinit();
            req = req.withContext(attempt_ctx.context());
            req.host = tls_config.server_name;
            req.close = true;
            req.addHeader(Http.Header.accept, "application/dns-message") catch return null;
            req.addHeader(Http.Header.content_type, "application/dns-message") catch return null;

            var body = SliceReadCloser{ .payload = qpkt.buf[0..qpkt.len] };
            req = req.withBody(Http.ReadCloser.init(&body));
            req.content_length = @intCast(qpkt.len);

            var resp = transport.roundTrip(&req) catch return null;
            defer resp.deinit();
            if (!resp.ok()) return null;
            if (!responseHasDnsMessageContentType(resp)) return null;

            var response_body = resp.body() orelse return null;
            return readResponseBody(&response_body, out) orelse return null;
        }

        const SliceReadCloser = struct {
            payload: []const u8,
            offset: usize = 0,

            pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                const remaining = self.payload[self.offset..];
                const n = @min(buf.len, remaining.len);
                @memcpy(buf[0..n], remaining[0..n]);
                self.offset += n;
                return n;
            }

            pub fn close(_: *@This()) void {}
        };

        fn formatDohUrl(server: Server, buf: []u8) ![]u8 {
            var host_buf: [96]u8 = undefined;
            const host = try formatDohHost(server.addr, &host_buf);
            const port = server.addr.port();
            if (port == 443) {
                return std.fmt.bufPrint(buf, "https://{s}{s}", .{ host, server.doh_path });
            }
            return std.fmt.bufPrint(buf, "https://{s}:{d}{s}", .{ host, port, server.doh_path });
        }

        fn formatDohHost(addr_port: AddrPort, buf: []u8) ![]u8 {
            const addr = addr_port.addr();
            if (addr.is4()) {
                const bytes = addr.as4().?;
                return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
                    bytes[0], bytes[1], bytes[2], bytes[3],
                });
            }
            if (addr.is6()) return formatIpv6Host(addr.as16().?, 0, buf);
            return error.InvalidResponse;
        }

        fn formatIpv6Host(bytes: [16]u8, _: u32, buf: []u8) ![]u8 {
            const groups = [8]u16{
                (@as(u16, bytes[0]) << 8) | bytes[1],
                (@as(u16, bytes[2]) << 8) | bytes[3],
                (@as(u16, bytes[4]) << 8) | bytes[5],
                (@as(u16, bytes[6]) << 8) | bytes[7],
                (@as(u16, bytes[8]) << 8) | bytes[9],
                (@as(u16, bytes[10]) << 8) | bytes[11],
                (@as(u16, bytes[12]) << 8) | bytes[13],
                (@as(u16, bytes[14]) << 8) | bytes[15],
            };

            return std.fmt.bufPrint(
                buf,
                "[{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}]",
                .{
                    groups[0], groups[1], groups[2], groups[3],
                    groups[4], groups[5], groups[6], groups[7],
                },
            );
        }

        fn responseHasDnsMessageContentType(resp: Http.Response) bool {
            for (resp.header) |hdr| {
                if (hdr.is(Http.Header.content_type)) {
                    const semi = std.mem.indexOfScalar(u8, hdr.value, ';') orelse hdr.value.len;
                    const media_type = std.mem.trim(u8, hdr.value[0..semi], " \t");
                    return std.ascii.eqlIgnoreCase(media_type, "application/dns-message");
                }
            }
            return false;
        }

        fn readResponseBody(body: *Http.ReadCloser, out: []u8) ?usize {
            var total: usize = 0;
            while (true) {
                if (total >= out.len) return null;
                const n = body.read(out[total..]) catch return null;
                if (n == 0) return total;
                total += n;
            }
        }

        fn streamAttempt(ctx: WorkerRacer.State, c: Conn, job: *LookupJob, timeout_ms: u32) ?WorkerResult {
            var conn = c;
            const started_ms = lib.time.milliTimestamp();

            for (job.queryPkts()) |qpkt| {
                var tcp_buf: [514]u8 = undefined;
                tcp_buf[0] = @truncate(qpkt.len >> 8);
                tcp_buf[1] = @truncate(qpkt.len);
                @memcpy(tcp_buf[2..][0..qpkt.len], qpkt.buf[0..qpkt.len]);
                tryWriteAll(ctx, &conn, tcp_buf[0 .. 2 + qpkt.len], started_ms, timeout_ms) orelse return null;
            }

            var result = WorkerResult{};
            var replied = [2]bool{ false, false };
            var replied_count: usize = 0;
            var handled = [2]bool{ false, false };
            var handled_count: usize = 0;

            while (handled_count < job.queryPkts().len) {
                var len_buf: [2]u8 = undefined;
                tryReadFull(ctx, &conn, &len_buf, started_ms, timeout_ms) orelse return null;

                const msg_len = readU16(&len_buf);
                if (msg_len < 12 or msg_len > 512) return null;

                var recv_buf: [512]u8 = undefined;
                tryReadFull(ctx, &conn, recv_buf[0..msg_len], started_ms, timeout_ms) orelse return null;

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
                return WorkerResult{ .has_result = true, .err = error.NoData };
            }
            return null;
        }

        fn tryWriteAll(ctx: WorkerRacer.State, conn: *Conn, buf: []const u8, started_ms: i64, timeout_ms: u32) ?void {
            var offset: usize = 0;
            while (offset < buf.len) {
                if (ctx.done()) return null;
                const io_timeout_ms = nextStreamTimeoutWorker(ctx, started_ms, timeout_ms) orelse return null;
                conn.setWriteTimeout(io_timeout_ms);
                const n = conn.write(buf[offset..]) catch |err| switch (err) {
                    error.TimedOut => continue,
                    else => return null,
                };
                if (n == 0) return null;
                offset += n;
            }
        }

        fn tryReadFull(ctx: WorkerRacer.State, conn: *Conn, buf: []u8, started_ms: i64, timeout_ms: u32) ?void {
            var offset: usize = 0;
            while (offset < buf.len) {
                if (ctx.done()) return null;
                const io_timeout_ms = nextStreamTimeoutWorker(ctx, started_ms, timeout_ms) orelse return null;
                conn.setReadTimeout(io_timeout_ms);
                const n = conn.read(buf[offset..]) catch |err| switch (err) {
                    error.TimedOut => continue,
                    else => return null,
                };
                if (n == 0) return null;
                offset += n;
            }
        }

        fn nextStreamTimeoutWorker(ctx: WorkerRacer.State, started_ms: i64, timeout_ms: u32) ?u32 {
            if (ctx.done()) return null;
            const now_ms = lib.time.milliTimestamp();
            const elapsed_ms = now_ms - started_ms;
            const remaining_query = @as(i64, timeout_ms) - elapsed_ms;
            if (remaining_query <= 0) return null;
            return @intCast(@max(@as(i64, 1), @min(remaining_query, worker_io_quantum_ms)));
        }

        fn validateServer(server: Server) LookupError!void {
            switch (server.protocol) {
                .tls, .doh => {
                    const tls_config = server.tls_config orelse return error.InvalidTlsConfig;
                    if (tls_config.server_name.len == 0) return error.InvalidTlsConfig;
                    if (server.protocol == .doh and (server.doh_path.len == 0 or server.doh_path[0] != '/')) {
                        return error.InvalidTlsConfig;
                    }
                },
                else => {},
            }
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

            const flags = readU16(pkt[2..4]);
            const qdcount = readU16(pkt[4..6]);
            const ancount = readU16(pkt[6..8]);
            if ((flags & 0x8000) == 0) return error.InvalidResponse;
            if ((flags & 0x0200) != 0) return error.InvalidResponse;
            if (qdcount != 1) return error.InvalidResponse;
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
                    out[count] = Addr.from4(pkt[pos..][0..4].*);
                    count += 1;
                } else if (rtype == qtype and rtype == QTYPE_AAAA and rdlength == 16) {
                    if (count >= out.len) {
                        pos += rdlength;
                        continue;
                    }
                    out[count] = Addr.from16(pkt[pos..][0..16].*);
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
                if ((len & 0xC0) != 0 or len > 63) return error.InvalidResponse;
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

fn writeResolverTestU16(buf: *[512]u8, pos: *usize, value: u16) void {
    buf[pos.*] = @truncate(value >> 8);
    buf[pos.* + 1] = @truncate(value);
    pos.* += 2;
}

fn readResolverTestU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

fn buildResolverTestAResponse(comptime R: type, req: []const u8, flags: u16, qdcount: u16, out: *[512]u8) !usize {
    if (req.len < 12) return error.InvalidResponse;

    var pos: usize = 0;
    writeResolverTestU16(out, &pos, readResolverTestU16(req[0..2]));
    writeResolverTestU16(out, &pos, flags);
    writeResolverTestU16(out, &pos, qdcount);
    writeResolverTestU16(out, &pos, 1);
    writeResolverTestU16(out, &pos, 0);
    writeResolverTestU16(out, &pos, 0);

    const question = req[12..];
    if (pos + question.len + 16 > out.len) return error.InvalidResponse;
    @memcpy(out[pos..][0..question.len], question);
    pos += question.len;

    out[pos] = 0xC0;
    out[pos + 1] = 0x0C;
    pos += 2;
    writeResolverTestU16(out, &pos, R.QTYPE_A);
    writeResolverTestU16(out, &pos, R.QCLASS_IN);
    out[pos] = 0;
    out[pos + 1] = 0;
    out[pos + 2] = 0x01;
    out[pos + 3] = 0x2C;
    pos += 4;
    writeResolverTestU16(out, &pos, 4);
    @memcpy(out[pos..][0..4], &[_]u8{ 1, 2, 3, 4 });
    pos += 4;
    return pos;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, _: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const R = Resolver(lib);

            {
                var req_buf: [512]u8 = undefined;
                const req_len = try R.buildQuery(&req_buf, "example.com", R.QTYPE_A, 0x1234);

                var resp_buf: [512]u8 = undefined;
                const resp_len = try buildResolverTestAResponse(R, req_buf[0..req_len], 0x0180, 1, &resp_buf);

                var addrs: [1]netip.Addr = undefined;
                try testing.expectError(error.InvalidResponse, R.parseResponse(resp_buf[0..resp_len], R.QTYPE_A, &addrs));
            }

            {
                var req_buf: [512]u8 = undefined;
                const req_len = try R.buildQuery(&req_buf, "example.com", R.QTYPE_A, 0x1234);

                var resp_buf: [512]u8 = undefined;
                const resp_len = try buildResolverTestAResponse(R, req_buf[0..req_len], 0x8380, 1, &resp_buf);

                var addrs: [1]netip.Addr = undefined;
                try testing.expectError(error.InvalidResponse, R.parseResponse(resp_buf[0..resp_len], R.QTYPE_A, &addrs));
            }

            {
                var req_buf: [512]u8 = undefined;
                const req_len = try R.buildQuery(&req_buf, "example.com", R.QTYPE_A, 0x1234);

                var resp_buf: [512]u8 = undefined;
                const resp_len = try buildResolverTestAResponse(R, req_buf[0..req_len], 0x8180, 0, &resp_buf);

                var addrs: [1]netip.Addr = undefined;
                try testing.expectError(error.InvalidResponse, R.parseResponse(resp_buf[0..resp_len], R.QTYPE_A, &addrs));
            }

            {
                var req_buf: [512]u8 = undefined;
                const req_len = try R.buildQuery(&req_buf, "example.com", R.QTYPE_A, 0x1234);

                var resp_buf: [512]u8 = undefined;
                const resp_len = try buildResolverTestAResponse(R, req_buf[0..req_len], 0x8180, 1, &resp_buf);
                resp_buf[12] = 0x40;

                var addrs: [1]netip.Addr = undefined;
                try testing.expectError(error.InvalidResponse, R.parseResponse(resp_buf[0..resp_len], R.QTYPE_A, &addrs));
            }
        }
    }.run);
}
