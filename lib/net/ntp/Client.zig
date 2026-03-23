const std = @import("std");
const context_mod = @import("context");
const sync = @import("sync");
const net_mod = @import("../../net.zig");

pub fn Client(comptime lib: type, comptime ntp: type) type {
    const Net = net_mod.Make(lib);
    const Addr = lib.net.Address;
    const Allocator = lib.mem.Allocator;
    const Thread = lib.Thread;
    const PacketConn = net_mod.PacketConn;
    const WorkerRacer = sync.Racer(lib, ntp.Response);

    return struct {
        allocator: Allocator,
        options: Options,
        mutex: Thread.Mutex = .{},
        cond: Thread.Condition = .{},
        deiniting: bool = false,
        active_races: usize = 0,

        const Self = @This();

        pub const Server = struct {
            addr: Addr,

            pub fn init(addr: Addr) Server {
                return .{ .addr = addr };
            }

            pub fn initIp(comptime ip: []const u8) Server {
                return .{ .addr = comptime Addr.parseIp(ip, ntp.NTP_PORT) catch unreachable };
            }
        };

        pub const Servers = struct {
            pub const aliyun = Server.initIp("203.107.6.88");
            pub const cloudflare = Server.initIp("162.159.200.1");
            pub const google = Server.initIp("216.239.35.0");
        };

        pub const Options = struct {
            servers: []const Server = &.{Servers.aliyun, Servers.cloudflare, Servers.google},
            timeout_ms: u32 = 5000,
            spawn_config: Thread.SpawnConfig = .{},
        };

        const RaceJob = struct {
            client: *Self,
            racer: WorkerRacer,
            origin_time_ms: i64,
            failure_mutex: Thread.Mutex = .{},
            saw_kiss_of_death: bool = false,
            saw_origin_mismatch: bool = false,
            saw_source_mismatch: bool = false,
            saw_invalid_response: bool = false,
            saw_send_failed: bool = false,
            saw_recv_failed: bool = false,

            fn recordFailure(self: *RaceJob, err: anyerror) void {
                self.failure_mutex.lock();
                defer self.failure_mutex.unlock();

                switch (err) {
                    error.KissOfDeath => self.saw_kiss_of_death = true,
                    error.OriginMismatch => self.saw_origin_mismatch = true,
                    error.SourceMismatch => self.saw_source_mismatch = true,
                    error.InvalidResponse => self.saw_invalid_response = true,
                    error.SendFailed => self.saw_send_failed = true,
                    error.RecvFailed => self.saw_recv_failed = true,
                    else => {},
                }
            }

            fn finalError(self: *RaceJob) anyerror {
                self.failure_mutex.lock();
                defer self.failure_mutex.unlock();

                if (self.saw_kiss_of_death) return error.KissOfDeath;
                if (self.saw_origin_mismatch) return error.OriginMismatch;
                if (self.saw_source_mismatch) return error.SourceMismatch;
                if (self.saw_invalid_response) return error.InvalidResponse;
                if (self.saw_send_failed) return error.SendFailed;
                if (self.saw_recv_failed) return error.RecvFailed;
                return error.Timeout;
            }
        };

        pub fn init(allocator: Allocator, options: Options) Allocator.Error!Self {
            const servers = try allocator.dupe(Server, options.servers);
            var owned = options;
            owned.servers = servers;
            return .{
                .allocator = allocator,
                .options = owned,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            self.deiniting = true;
            while (self.active_races != 0) self.cond.wait(&self.mutex);
            self.mutex.unlock();

            self.allocator.free(self.options.servers);
            self.* = undefined;
        }

        pub fn wait(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.active_races != 0) self.cond.wait(&self.mutex);
        }

        pub fn query(self: *Self, origin_time_ms: i64) anyerror!ntp.Response {
            const Context = context_mod.Make(lib);
            var context_api = try Context.init(self.allocator);
            defer context_api.deinit();
            return self.queryContext(context_api.background(), origin_time_ms);
        }

        pub fn queryContext(self: *Self, ctx: context_mod.Context, origin_time_ms: i64) anyerror!ntp.Response {
            if (self.options.servers.len == 0) return error.NoServerConfigured;
            if (self.options.servers.len > 1) return self.queryRaceContext(ctx, origin_time_ms);
            return self.queryServerContext(ctx, self.options.servers[0], origin_time_ms);
        }

        pub fn queryServer(self: *Self, server: Server, origin_time_ms: i64) anyerror!ntp.Response {
            const Context = context_mod.Make(lib);
            var context_api = try Context.init(self.allocator);
            defer context_api.deinit();
            return self.queryServerContext(context_api.background(), server, origin_time_ms);
        }

        pub fn queryServerContext(self: *Self, ctx: context_mod.Context, server: Server, origin_time_ms: i64) anyerror!ntp.Response {
            try ensureContextActive(ctx);
            return self.queryWithContext(ctx, server, normalizedOriginTimeMs(origin_time_ms));
        }

        pub fn getTime(self: *Self, origin_time_ms: i64) anyerror!i64 {
            const resp = try self.query(origin_time_ms);
            return resp.transmit_time_ms;
        }

        pub fn getTimeContext(self: *Self, ctx: context_mod.Context, origin_time_ms: i64) anyerror!i64 {
            const resp = try self.queryContext(ctx, origin_time_ms);
            return resp.transmit_time_ms;
        }

        pub fn queryRace(self: *Self, origin_time_ms: i64) anyerror!ntp.Response {
            const Context = context_mod.Make(lib);
            var context_api = try Context.init(self.allocator);
            defer context_api.deinit();
            return self.queryRaceContext(context_api.background(), origin_time_ms);
        }

        pub fn queryRaceContext(self: *Self, ctx: context_mod.Context, origin_time_ms: i64) anyerror!ntp.Response {
            if (self.options.servers.len == 0) return error.NoServerConfigured;
            try ensureContextActive(ctx);

            try self.beginRace();
            var needs_finish_race = true;
            errdefer if (needs_finish_race) self.finishRace();

            const job = self.allocator.create(RaceJob) catch return error.OutOfMemory;
            var owns_job = false;
            var destroy_raw_job_on_error = true;
            errdefer if (destroy_raw_job_on_error) self.allocator.destroy(job);

            job.* = .{
                .client = self,
                .racer = undefined,
                .origin_time_ms = normalizedOriginTimeMs(origin_time_ms),
            };
            job.racer = WorkerRacer.init(self.allocator) catch return error.OutOfMemory;
            destroy_raw_job_on_error = false;

            owns_job = true;
            defer if (owns_job) self.destroyRaceJob(job);
            needs_finish_race = false;

            var spawned: usize = 0;
            var spawn_err: ?Thread.SpawnError = null;
            for (self.options.servers) |server| {
                job.racer.spawn(self.options.spawn_config, raceWorker, .{ job, server }) catch |err| {
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

            const winner = switch (race_result) {
                .winner => |resp| resp,
                .exhausted => return job.finalError(),
            };

            if (self.beginCleanup(job)) {
                owns_job = false;
            } else {
                job.racer.wait();
            }
            return winner;
        }

        pub fn getTimeRace(self: *Self, origin_time_ms: i64) anyerror!i64 {
            const resp = try self.queryRace(origin_time_ms);
            return resp.transmit_time_ms;
        }

        pub fn getTimeRaceContext(self: *Self, ctx: context_mod.Context, origin_time_ms: i64) anyerror!i64 {
            const resp = try self.queryRaceContext(ctx, origin_time_ms);
            return resp.transmit_time_ms;
        }

        fn raceWorker(state: WorkerRacer.State, job: *RaceJob, server: Server) void {
            const resp = job.client.queryWithWorker(state, server, job.origin_time_ms) catch |err| {
                if (!state.done()) job.recordFailure(err);
                return;
            };
            if (resp) |response| {
                _ = state.success(response);
            }
        }

        fn queryWithContext(self: *Self, ctx: context_mod.Context, server: Server, origin_time_ms: i64) anyerror!ntp.Response {
            var pc = try self.openPacketConn(server.addr);
            defer pc.deinit();

            var request: [48]u8 = undefined;
            ntp.buildRequest(&request, origin_time_ms);
            const expected_origin = ntp.unixMsToNtp(origin_time_ms);

            const write_timeout_ms = initialWriteTimeoutMs(ctx, self.options.timeout_ms);
            pc.setWriteTimeout(write_timeout_ms);
            const sent = pc.writeTo(request[0..], @ptrCast(&server.addr.any), server.addr.getOsSockLen()) catch return error.SendFailed;
            if (sent != request.len) return error.SendFailed;

            const started_ms = lib.time.milliTimestamp();
            while (true) {
                if (ctx.err()) |err| return err;

                const read_timeout_ms = nextReadTimeoutContext(ctx, started_ms, self.options.timeout_ms) orelse return timeoutForContext(ctx);
                pc.setReadTimeout(read_timeout_ms);

                var recv_buf: [128]u8 = undefined;
                const result = pc.readFrom(&recv_buf) catch |err| switch (err) {
                    error.TimedOut => {
                        if (ctx.err()) |cause| return cause;
                        if (ctx.deadline()) |deadline_ms| {
                            if (deadline_ms <= lib.time.milliTimestamp()) return error.DeadlineExceeded;
                        }
                        if (queryTimedOut(started_ms, self.options.timeout_ms)) return error.Timeout;
                        continue;
                    },
                    else => return error.RecvFailed,
                };

                if (!addrMatches(result, server.addr)) return error.SourceMismatch;
                if (result.bytes_read < 48) return error.InvalidResponse;

                var packet: [48]u8 = undefined;
                @memcpy(&packet, recv_buf[0..48]);
                return ntp.parseResponse(&packet, expected_origin);
            }
        }

        fn queryWithWorker(self: *Self, state: WorkerRacer.State, server: Server, origin_time_ms: i64) anyerror!?ntp.Response {
            if (state.done()) return null;

            var pc = try self.openPacketConn(server.addr);
            defer pc.deinit();

            var request: [48]u8 = undefined;
            ntp.buildRequest(&request, origin_time_ms);
            const expected_origin = ntp.unixMsToNtp(origin_time_ms);

            pc.setWriteTimeout(if (self.options.timeout_ms == 0) 1 else self.options.timeout_ms);
            const sent = pc.writeTo(request[0..], @ptrCast(&server.addr.any), server.addr.getOsSockLen()) catch return error.SendFailed;
            if (sent != request.len) return error.SendFailed;

            const started_ms = lib.time.milliTimestamp();
            while (true) {
                if (state.done()) return null;

                const read_timeout_ms = nextReadTimeoutWorker(state, started_ms, self.options.timeout_ms) orelse return if (state.done()) null else error.Timeout;
                pc.setReadTimeout(read_timeout_ms);

                var recv_buf: [128]u8 = undefined;
                const result = pc.readFrom(&recv_buf) catch |err| switch (err) {
                    error.TimedOut => {
                        if (state.done()) return null;
                        if (queryTimedOut(started_ms, self.options.timeout_ms)) return error.Timeout;
                        continue;
                    },
                    else => return error.RecvFailed,
                };

                if (!addrMatches(result, server.addr)) return error.SourceMismatch;
                if (result.bytes_read < 48) return error.InvalidResponse;

                var packet: [48]u8 = undefined;
                @memcpy(&packet, recv_buf[0..48]);
                return try ntp.parseResponse(&packet, expected_origin);
            }
        }

        fn openPacketConn(self: *Self, addr: Addr) anyerror!PacketConn {
            return Net.listenPacket(.{
                .allocator = self.allocator,
                .address = anyAddressFor(addr),
            });
        }

        fn anyAddressFor(addr: Addr) Addr {
            return switch (addr.any.family) {
                lib.posix.AF.INET => Addr.initIp4(.{ 0, 0, 0, 0 }, 0),
                lib.posix.AF.INET6 => Addr.initIp6(.{0} ** 16, 0, 0, 0),
                else => unreachable,
            };
        }

        fn addrMatches(result: PacketConn.ReadFromResult, expected: Addr) bool {
            const expected_len = expected.getOsSockLen();
            if (result.addr_len != expected_len) return false;

            const expected_bytes: []const u8 = switch (expected.any.family) {
                lib.posix.AF.INET => std.mem.asBytes(&expected.in.sa)[0..expected_len],
                lib.posix.AF.INET6 => std.mem.asBytes(&expected.in6.sa)[0..expected_len],
                else => return false,
            };
            return std.mem.eql(u8, result.addr[0..expected_len], expected_bytes);
        }

        fn initialWriteTimeoutMs(ctx: context_mod.Context, timeout_ms: u32) ?u32 {
            if (timeout_ms == 0) return 1;
            if (ctx.deadline()) |deadline_ms| {
                const remaining = deadline_ms - lib.time.milliTimestamp();
                if (remaining <= 0) return 1;
                return @intCast(@max(@as(i64, 1), @min(@as(i64, timeout_ms), remaining)));
            }
            return timeout_ms;
        }

        fn nextReadTimeoutContext(ctx: context_mod.Context, started_ms: i64, timeout_ms: u32) ?u32 {
            const now_ms = lib.time.milliTimestamp();
            const elapsed_ms = now_ms - started_ms;
            const remaining_query = @as(i64, timeout_ms) - elapsed_ms;
            if (remaining_query <= 0) return null;

            var remaining_ms = remaining_query;
            if (ctx.deadline()) |deadline_ms| {
                const remaining_ctx = deadline_ms - now_ms;
                if (remaining_ctx <= 0) return null;
                remaining_ms = @min(remaining_ms, remaining_ctx);
            }

            return @intCast(@max(@as(i64, 1), @min(remaining_ms, 50)));
        }

        fn nextReadTimeoutWorker(state: WorkerRacer.State, started_ms: i64, timeout_ms: u32) ?u32 {
            if (state.done()) return null;
            const now_ms = lib.time.milliTimestamp();
            const elapsed_ms = now_ms - started_ms;
            const remaining_query = @as(i64, timeout_ms) - elapsed_ms;
            if (remaining_query <= 0) return null;
            return @intCast(@max(@as(i64, 1), @min(remaining_query, 50)));
        }

        fn queryTimedOut(started_ms: i64, timeout_ms: u32) bool {
            return lib.time.milliTimestamp() - started_ms >= timeout_ms;
        }

        fn timeoutForContext(ctx: context_mod.Context) anyerror {
            if (ctx.err()) |err| return err;
            if (ctx.deadline()) |deadline_ms| {
                if (deadline_ms <= lib.time.milliTimestamp()) return error.DeadlineExceeded;
            }
            return error.Timeout;
        }

        fn ensureContextActive(ctx: context_mod.Context) anyerror!void {
            if (ctx.err()) |err| return err;
            if (ctx.deadline()) |deadline_ms| {
                if (deadline_ms <= lib.time.milliTimestamp()) return error.DeadlineExceeded;
            }
        }

        fn normalizedOriginTimeMs(origin_time_ms: i64) i64 {
            return if (origin_time_ms != 0) origin_time_ms else 1;
        }

        fn beginRace(self: *Self) error{Closed}!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.deiniting) return error.Closed;
            self.active_races += 1;
        }

        fn finishRace(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            std.debug.assert(self.active_races > 0);
            self.active_races -= 1;
            if (self.active_races == 0) self.cond.broadcast();
        }

        fn beginCleanup(self: *Self, job: *RaceJob) bool {
            var t = Thread.spawn(self.cleanupSpawnConfig(), cleanupFn, .{job}) catch return false;
            t.detach();
            return true;
        }

        fn cleanupFn(job: *RaceJob) void {
            job.client.destroyRaceJob(job);
        }

        fn destroyRaceJob(self: *Self, job: *RaceJob) void {
            job.racer.deinit();
            self.allocator.destroy(job);
            self.finishRace();
        }

        fn cleanupSpawnConfig(self: *Self) Thread.SpawnConfig {
            var config = self.options.spawn_config;
            if (@hasField(Thread.SpawnConfig, "allocator")) {
                if (config.allocator == null) config.allocator = self.allocator;
            }
            return config;
        }
    };
}
