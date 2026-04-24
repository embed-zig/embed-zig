const std = @import("std");
const context_mod = @import("context");
const sync = @import("sync");

pub fn Client(comptime lib: type, comptime net: type, comptime ntp: type) type {
    const Net = net;
    const Addr = net.netip.AddrPort;
    const IpAddr = net.netip.Addr;
    const Allocator = lib.mem.Allocator;
    const Thread = lib.Thread;
    const PacketConn = net.PacketConn;
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
                return .{ .addr = Addr.init(comptime IpAddr.parse(ip) catch unreachable, ntp.NTP_PORT) };
            }
        };

        pub const Servers = struct {
            pub const aliyun = Server.initIp("203.107.6.88");
            pub const cloudflare = Server.initIp("162.159.200.1");
            pub const google = Server.initIp("216.239.35.0");
        };

        pub const Options = struct {
            servers: []const Server = &.{ Servers.aliyun, Servers.cloudflare, Servers.google },
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
            const Context = context_mod.make(lib);
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
            const Context = context_mod.make(lib);
            var context_api = try Context.init(self.allocator);
            defer context_api.deinit();
            return self.queryServerContext(context_api.background(), server, origin_time_ms);
        }

        pub fn queryServerContext(self: *Self, ctx: context_mod.Context, server: Server, origin_time_ms: i64) anyerror!ntp.Response {
            try ensureContextActive(ctx);
            try self.beginRace();
            defer self.finishRace();
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
            const Context = context_mod.make(lib);
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
                job.racer.cancel();
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
            const sent = pc.writeTo(request[0..], server.addr) catch return error.SendFailed;
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
                        if (ctx.deadline()) |deadline_ns| {
                            if (deadline_ns <= lib.time.nanoTimestamp()) return error.DeadlineExceeded;
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
            const sent = pc.writeTo(request[0..], server.addr) catch return error.SendFailed;
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
            if (addr.addr().is4()) return Addr.from4(.{ 0, 0, 0, 0 }, 0);
            if (addr.addr().is6()) return Addr.init(IpAddr.from16(.{0} ** 16), 0);
            unreachable;
        }

        fn addrMatches(result: PacketConn.ReadFromResult, expected: Addr) bool {
            return result.addr.port() == expected.port() and
                net.netip.Addr.compare(result.addr.addr(), expected.addr()) == .eq;
        }

        fn initialWriteTimeoutMs(ctx: context_mod.Context, timeout_ms: u32) ?u32 {
            if (timeout_ms == 0) return 1;
            if (ctx.deadline()) |deadline_ns| {
                const remaining = @divFloor(deadline_ns - lib.time.nanoTimestamp(), lib.time.ns_per_ms);
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
            if (ctx.deadline()) |deadline_ns| {
                const remaining_ctx: i64 = @intCast(@divFloor(deadline_ns - lib.time.nanoTimestamp(), lib.time.ns_per_ms));
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
            if (ctx.deadline()) |deadline_ns| {
                if (deadline_ns <= lib.time.nanoTimestamp()) return error.DeadlineExceeded;
            }
            return error.Timeout;
        }

        fn ensureContextActive(ctx: context_mod.Context) anyerror!void {
            if (ctx.err()) |err| return err;
            if (ctx.deadline()) |deadline_ns| {
                if (deadline_ns <= lib.time.nanoTimestamp()) return error.DeadlineExceeded;
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

pub fn TestRunner(comptime lib: type, comptime net: type, comptime ntp: type) @import("testing").TestRunner {
    _ = net;

    const testing_api = @import("testing");
    const PacketConnApi = @import("../PacketConn.zig");
    const netip_mod = @import("../netip.zig");
    const wire_mod = @import("wire.zig");
    const AddrPort = netip_mod.AddrPort;

    return testing_api.TestRunner.fromFn(lib, 3 * 1024 * 1024, struct {
        const FakePacketConn = struct {
            response_addr: AddrPort = AddrPort.from4(.{ 127, 0, 0, 1 }, ntp.NTP_PORT),
            response_len: usize = 0,
            response_buf: [48]u8 = [_]u8{0} ** 48,
            write_to_addr: ?AddrPort = null,
            write_timeout_ms: ?u32 = null,
            read_timeout_ms: ?u32 = null,
            close_calls: usize = 0,
            deinit_calls: usize = 0,

            pub fn readFrom(conn: *FakePacketConn, buf: []u8) PacketConnApi.ReadFromError!PacketConnApi.ReadFromResult {
                const n = @min(buf.len, conn.response_len);
                @memcpy(buf[0..n], conn.response_buf[0..n]);
                return .{
                    .bytes_read = n,
                    .addr = conn.response_addr,
                };
            }

            pub fn writeTo(conn: *FakePacketConn, buf: []const u8, addr: AddrPort) PacketConnApi.WriteToError!usize {
                conn.write_to_addr = addr;
                return buf.len;
            }

            pub fn close(conn: *FakePacketConn) void {
                conn.close_calls += 1;
            }

            pub fn deinit(conn: *FakePacketConn) void {
                conn.deinit_calls += 1;
            }

            pub fn setReadTimeout(conn: *FakePacketConn, ms: ?u32) void {
                conn.read_timeout_ms = ms;
            }

            pub fn setWriteTimeout(conn: *FakePacketConn, ms: ?u32) void {
                conn.write_timeout_ms = ms;
            }
        };

        const FakeState = struct {
            var active_conn: ?*FakePacketConn = null;
            var opened_addr: ?AddrPort = null;
        };

        const FakeNet = struct {
            pub const PacketConn = PacketConnApi;
            pub const netip = netip_mod;

            pub fn listenPacket(opts: anytype) !PacketConn {
                FakeState.opened_addr = opts.address;
                const conn = FakeState.active_conn orelse unreachable;
                return PacketConnApi.init(conn);
            }
        };

        const ClientApi = Client(lib, FakeNet, ntp);

        fn buildResponse(origin_ms: i64, receive_ms: i64, transmit_ms: i64, stratum: u8) [48]u8 {
            var buf: [48]u8 = [_]u8{0} ** 48;
            buf[0] = 0b00_100_100;
            buf[1] = stratum;
            wire_mod.writeTimestamp(buf[24..32], wire_mod.unixMsToNtp(origin_ms));
            wire_mod.writeTimestamp(buf[32..40], wire_mod.unixMsToNtp(receive_ms));
            wire_mod.writeTimestamp(buf[40..48], wire_mod.unixMsToNtp(transmit_ms));
            return buf;
        }

        fn expectAddrPortEqual(testing: anytype, actual: AddrPort, expected: AddrPort) !void {
            try testing.expectEqual(expected.port(), actual.port());
            try testing.expect(netip_mod.Addr.compare(actual.addr(), expected.addr()) == .eq);
        }

        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const origin_ms: i64 = 1_706_012_096_000;
            const server = ClientApi.Server.init(AddrPort.from4(.{ 203, 107, 6, 88 }, ntp.NTP_PORT));

            var client = try ClientApi.init(allocator, .{
                .servers = &.{server},
                .timeout_ms = 250,
            });
            defer client.deinit();

            var good_conn = FakePacketConn{
                .response_addr = server.addr,
                .response_len = 48,
                .response_buf = buildResponse(origin_ms, origin_ms + 12, origin_ms + 20, 2),
            };
            FakeState.active_conn = &good_conn;
            FakeState.opened_addr = null;

            const resp = try client.queryServer(server, origin_ms);
            try testing.expectEqual(@as(u8, 2), resp.stratum);
            try testing.expect(@abs(resp.receive_time_ms - (origin_ms + 12)) <= 1);
            try testing.expect(@abs(resp.transmit_time_ms - (origin_ms + 20)) <= 1);
            try expectAddrPortEqual(testing, good_conn.write_to_addr.?, server.addr);
            try expectAddrPortEqual(testing, FakeState.opened_addr.?, AddrPort.from4(.{ 0, 0, 0, 0 }, 0));
            try testing.expect(good_conn.write_timeout_ms != null);
            try testing.expect(good_conn.read_timeout_ms != null);
            try testing.expectEqual(@as(usize, 1), good_conn.close_calls);
            try testing.expectEqual(@as(usize, 1), good_conn.deinit_calls);

            var bad_conn = FakePacketConn{
                .response_addr = AddrPort.from4(.{ 1, 1, 1, 1 }, ntp.NTP_PORT),
                .response_len = 48,
                .response_buf = buildResponse(origin_ms, origin_ms + 12, origin_ms + 20, 2),
            };
            FakeState.active_conn = &bad_conn;
            FakeState.opened_addr = null;

            try testing.expectError(error.SourceMismatch, client.queryServer(server, origin_ms));
            try expectAddrPortEqual(testing, bad_conn.write_to_addr.?, server.addr);
            try testing.expectEqual(@as(usize, 1), bad_conn.close_calls);
            try testing.expectEqual(@as(usize, 1), bad_conn.deinit_calls);
        }
    }.run);
}
