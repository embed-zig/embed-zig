const time_mod = @import("time");
const host_std = @import("std");
const context_mod = @import("context");
const sync = @import("sync");

pub fn Client(comptime std: type, comptime net: type, comptime ntp: type) type {
    const Net = net;
    const Addr = net.netip.AddrPort;
    const IpAddr = net.netip.Addr;
    const Allocator = std.mem.Allocator;
    const Thread = std.Thread;
    const PacketConn = net.PacketConn;
    const WorkerRacer = sync.Racer(std, net.time, ntp.Response);

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
            timeout: time_mod.duration.Duration = 5 * time_mod.duration.Second,
            spawn_config: Thread.SpawnConfig = .{},
        };

        const RaceJob = struct {
            client: *Self,
            racer: WorkerRacer,
            origin_time: time_mod.Time,
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

        const read_quantum: time_mod.duration.Duration = 50 * time_mod.duration.MilliSecond;

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

        pub fn query(self: *Self, origin_time: time_mod.Time) anyerror!ntp.Response {
            const Context = context_mod.make(std, net.time);
            var context_api = try Context.init(self.allocator);
            defer context_api.deinit();
            return self.queryContext(context_api.background(), origin_time);
        }

        pub fn queryContext(self: *Self, ctx: context_mod.Context, origin_time: time_mod.Time) anyerror!ntp.Response {
            if (self.options.servers.len == 0) return error.NoServerConfigured;
            if (self.options.servers.len > 1) return self.queryRaceContext(ctx, origin_time);
            return self.queryServerContext(ctx, self.options.servers[0], origin_time);
        }

        pub fn queryServer(self: *Self, server: Server, origin_time: time_mod.Time) anyerror!ntp.Response {
            const Context = context_mod.make(std, net.time);
            var context_api = try Context.init(self.allocator);
            defer context_api.deinit();
            return self.queryServerContext(context_api.background(), server, origin_time);
        }

        pub fn queryServerContext(self: *Self, ctx: context_mod.Context, server: Server, origin_time: time_mod.Time) anyerror!ntp.Response {
            try ensureContextActive(ctx);
            try self.beginRace();
            defer self.finishRace();
            return self.queryWithContext(ctx, server, normalizedOriginTime(origin_time));
        }

        pub fn getTime(self: *Self, origin_time: time_mod.Time) anyerror!time_mod.Time {
            const resp = try self.query(origin_time);
            return resp.transmit_time;
        }

        pub fn getTimeContext(self: *Self, ctx: context_mod.Context, origin_time: time_mod.Time) anyerror!time_mod.Time {
            const resp = try self.queryContext(ctx, origin_time);
            return resp.transmit_time;
        }

        pub fn queryRace(self: *Self, origin_time: time_mod.Time) anyerror!ntp.Response {
            const Context = context_mod.make(std, net.time);
            var context_api = try Context.init(self.allocator);
            defer context_api.deinit();
            return self.queryRaceContext(context_api.background(), origin_time);
        }

        pub fn queryRaceContext(self: *Self, ctx: context_mod.Context, origin_time: time_mod.Time) anyerror!ntp.Response {
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
                .origin_time = normalizedOriginTime(origin_time),
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

        pub fn getTimeRace(self: *Self, origin_time: time_mod.Time) anyerror!time_mod.Time {
            const resp = try self.queryRace(origin_time);
            return resp.transmit_time;
        }

        pub fn getTimeRaceContext(self: *Self, ctx: context_mod.Context, origin_time: time_mod.Time) anyerror!time_mod.Time {
            const resp = try self.queryRaceContext(ctx, origin_time);
            return resp.transmit_time;
        }

        fn raceWorker(state: WorkerRacer.State, job: *RaceJob, server: Server) void {
            const resp = job.client.queryWithWorker(state, server, job.origin_time) catch |err| {
                if (!state.done()) job.recordFailure(err);
                return;
            };
            if (resp) |response| {
                _ = state.success(response);
            }
        }

        fn queryWithContext(self: *Self, ctx: context_mod.Context, server: Server, origin_time: time_mod.Time) anyerror!ntp.Response {
            var pc = try self.openPacketConn(server.addr);
            defer pc.deinit();

            var request: [48]u8 = undefined;
            ntp.buildRequest(&request, origin_time);
            const expected_origin = ntp.timeToNtp(origin_time);

            const write_timeout = initialWriteTimeout(ctx, self.options.timeout);
            pc.setWriteDeadline(if (write_timeout) |timeout| time_mod.instant.add(net.time.instant.now(), timeout) else null);
            const sent = pc.writeTo(request[0..], server.addr) catch return error.SendFailed;
            if (sent != request.len) return error.SendFailed;

            const started = net.time.instant.now();
            while (true) {
                if (ctx.err()) |err| return err;

                const read_timeout = nextReadTimeoutContext(ctx, started, self.options.timeout) orelse return timeoutForContext(ctx);
                pc.setReadDeadline(time_mod.instant.add(net.time.instant.now(), read_timeout));

                var recv_buf: [128]u8 = undefined;
                const result = pc.readFrom(&recv_buf) catch |err| switch (err) {
                    error.TimedOut => {
                        if (ctx.err()) |cause| return cause;
                        if (ctx.deadline()) |deadline| {
                            if (time_mod.instant.sub(deadline, net.time.instant.now()) <= 0) return error.DeadlineExceeded;
                        }
                        if (queryTimedOut(started, self.options.timeout)) return error.Timeout;
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

        fn queryWithWorker(self: *Self, state: WorkerRacer.State, server: Server, origin_time: time_mod.Time) anyerror!?ntp.Response {
            if (state.done()) return null;

            var pc = try self.openPacketConn(server.addr);
            defer pc.deinit();

            var request: [48]u8 = undefined;
            ntp.buildRequest(&request, origin_time);
            const expected_origin = ntp.timeToNtp(origin_time);

            pc.setWriteDeadline(time_mod.instant.add(net.time.instant.now(), if (self.options.timeout <= 0) 1 else self.options.timeout));
            const sent = pc.writeTo(request[0..], server.addr) catch return error.SendFailed;
            if (sent != request.len) return error.SendFailed;

            const started = net.time.instant.now();
            while (true) {
                if (state.done()) return null;

                const read_timeout = nextReadTimeoutWorker(state, started, self.options.timeout) orelse return if (state.done()) null else error.Timeout;
                pc.setReadDeadline(time_mod.instant.add(net.time.instant.now(), read_timeout));

                var recv_buf: [128]u8 = undefined;
                const result = pc.readFrom(&recv_buf) catch |err| switch (err) {
                    error.TimedOut => {
                        if (state.done()) return null;
                        if (queryTimedOut(started, self.options.timeout)) return error.Timeout;
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

        fn initialWriteTimeout(ctx: context_mod.Context, timeout: time_mod.duration.Duration) ?time_mod.duration.Duration {
            if (timeout <= 0) return 1;
            if (ctx.deadline()) |deadline| {
                const remaining = @max(time_mod.instant.sub(deadline, net.time.instant.now()), 0);
                if (remaining <= 0) return 1;
                return @max(@as(time_mod.duration.Duration, 1), @min(timeout, remaining));
            }
            return timeout;
        }

        fn nextReadTimeoutContext(ctx: context_mod.Context, started: time_mod.instant.Time, timeout: time_mod.duration.Duration) ?time_mod.duration.Duration {
            const elapsed = time_mod.instant.sub(net.time.instant.now(), started);
            const remaining_query = timeout - elapsed;
            if (remaining_query <= 0) return null;

            var remaining = remaining_query;
            if (ctx.deadline()) |deadline| {
                const remaining_ctx = @max(time_mod.instant.sub(deadline, net.time.instant.now()), 0);
                if (remaining_ctx <= 0) return null;
                remaining = @min(remaining, remaining_ctx);
            }

            return @max(@as(time_mod.duration.Duration, 1), @min(remaining, read_quantum));
        }

        fn nextReadTimeoutWorker(state: WorkerRacer.State, started: time_mod.instant.Time, timeout: time_mod.duration.Duration) ?time_mod.duration.Duration {
            if (state.done()) return null;
            const elapsed = time_mod.instant.sub(net.time.instant.now(), started);
            const remaining_query = timeout - elapsed;
            if (remaining_query <= 0) return null;
            return @max(@as(time_mod.duration.Duration, 1), @min(remaining_query, read_quantum));
        }

        fn queryTimedOut(started: time_mod.instant.Time, timeout: time_mod.duration.Duration) bool {
            return time_mod.instant.sub(net.time.instant.now(), started) >= timeout;
        }

        fn timeoutForContext(ctx: context_mod.Context) anyerror {
            if (ctx.err()) |err| return err;
            if (ctx.deadline()) |deadline| {
                if (time_mod.instant.sub(deadline, net.time.instant.now()) <= 0) return error.DeadlineExceeded;
            }
            return error.Timeout;
        }

        fn ensureContextActive(ctx: context_mod.Context) anyerror!void {
            if (ctx.err()) |err| return err;
            if (ctx.deadline()) |deadline| {
                if (time_mod.instant.sub(deadline, net.time.instant.now()) <= 0) return error.DeadlineExceeded;
            }
        }

        fn normalizedOriginTime(origin_time: time_mod.Time) time_mod.Time {
            return if (!origin_time.isZero()) origin_time else net.time.now();
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

            host_std.debug.assert(self.active_races > 0);
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

pub fn TestRunner(comptime std: type, comptime net: type, comptime ntp: type) @import("testing").TestRunner {
    const testing_api = @import("testing");
    const PacketConnApi = @import("../PacketConn.zig");
    const netip_mod = @import("../netip.zig");
    const wire_mod = @import("wire.zig");
    const AddrPort = netip_mod.AddrPort;

    return testing_api.TestRunner.fromFn(std, 3 * 1024 * 1024, struct {
        const FakePacketConn = struct {
            response_addr: AddrPort = AddrPort.from4(.{ 127, 0, 0, 1 }, ntp.NTP_PORT),
            response_len: usize = 0,
            response_buf: [48]u8 = [_]u8{0} ** 48,
            write_to_addr: ?AddrPort = null,
            write_deadline: ?time_mod.instant.Time = null,
            read_deadline: ?time_mod.instant.Time = null,
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

            pub fn setReadDeadline(conn: *FakePacketConn, deadline: ?time_mod.instant.Time) void {
                conn.read_deadline = deadline;
            }

            pub fn setWriteDeadline(conn: *FakePacketConn, deadline: ?time_mod.instant.Time) void {
                conn.write_deadline = deadline;
            }
        };

        const FakeState = struct {
            var active_conn: ?*FakePacketConn = null;
            var opened_addr: ?AddrPort = null;
        };

        const FakeNet = struct {
            pub const time = net.time;
            pub const PacketConn = PacketConnApi;
            pub const netip = netip_mod;

            pub fn listenPacket(opts: anytype) !PacketConn {
                FakeState.opened_addr = opts.address;
                const conn = FakeState.active_conn orelse unreachable;
                return PacketConnApi.init(conn);
            }
        };

        const ClientApi = Client(std, FakeNet, ntp);

        fn buildResponse(origin_time: time_mod.Time, receive_time: time_mod.Time, transmit_time: time_mod.Time, stratum: u8) [48]u8 {
            var buf: [48]u8 = [_]u8{0} ** 48;
            buf[0] = 0b00_100_100;
            buf[1] = stratum;
            wire_mod.writeTimestamp(buf[24..32], wire_mod.timeToNtp(origin_time));
            wire_mod.writeTimestamp(buf[32..40], wire_mod.timeToNtp(receive_time));
            wire_mod.writeTimestamp(buf[40..48], wire_mod.timeToNtp(transmit_time));
            return buf;
        }

        fn expectAddrPortEqual(testing: anytype, actual: AddrPort, expected: AddrPort) !void {
            try testing.expectEqual(expected.port(), actual.port());
            try testing.expect(netip_mod.Addr.compare(actual.addr(), expected.addr()) == .eq);
        }

        fn run(_: *testing_api.T, allocator: std.mem.Allocator) !void {
            const testing = std.testing;
            const origin_time = time_mod.fromUnixMilli(1_706_012_096_000);
            const receive_time = origin_time.add(12 * time_mod.duration.MilliSecond);
            const transmit_time = origin_time.add(20 * time_mod.duration.MilliSecond);
            const server = ClientApi.Server.init(AddrPort.from4(.{ 203, 107, 6, 88 }, ntp.NTP_PORT));

            var client = try ClientApi.init(allocator, .{
                .servers = &.{server},
                .timeout = 250 * net.time.duration.MilliSecond,
            });
            defer client.deinit();

            var good_conn = FakePacketConn{
                .response_addr = server.addr,
                .response_len = 48,
                .response_buf = buildResponse(origin_time, receive_time, transmit_time, 2),
            };
            FakeState.active_conn = &good_conn;
            FakeState.opened_addr = null;

            const resp = try client.queryServer(server, origin_time);
            try testing.expectEqual(@as(u8, 2), resp.stratum);
            try testing.expect(@abs(resp.receive_time.sub(receive_time)) <= time_mod.duration.MicroSecond);
            try testing.expect(@abs(resp.transmit_time.sub(transmit_time)) <= time_mod.duration.MicroSecond);
            try expectAddrPortEqual(testing, good_conn.write_to_addr.?, server.addr);
            try expectAddrPortEqual(testing, FakeState.opened_addr.?, AddrPort.from4(.{ 0, 0, 0, 0 }, 0));
            try testing.expect(good_conn.write_deadline != null);
            try testing.expect(good_conn.read_deadline != null);
            try testing.expectEqual(@as(usize, 1), good_conn.close_calls);
            try testing.expectEqual(@as(usize, 1), good_conn.deinit_calls);

            var bad_conn = FakePacketConn{
                .response_addr = AddrPort.from4(.{ 1, 1, 1, 1 }, ntp.NTP_PORT),
                .response_len = 48,
                .response_buf = buildResponse(origin_time, receive_time, transmit_time, 2),
            };
            FakeState.active_conn = &bad_conn;
            FakeState.opened_addr = null;

            try testing.expectError(error.SourceMismatch, client.queryServer(server, origin_time));
            try expectAddrPortEqual(testing, bad_conn.write_to_addr.?, server.addr);
            try testing.expectEqual(@as(usize, 1), bad_conn.close_calls);
            try testing.expectEqual(@as(usize, 1), bad_conn.deinit_calls);
        }
    }.run);
}
