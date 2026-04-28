//! NTP test runner — public-network integration tests.
//!
//! These tests hit public Aliyun NTP directly, so they are intended for
//! environments with real network connectivity.
//!
//! Usage:
//!   const runner = @import("net/test_runner/integration/public/ntp.zig").make(lib, net);
//!   t.run("net/ntp", runner);

const context_mod = @import("context");
const stdz = @import("stdz");
const testing_api = @import("testing");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            runImpl(std, net, t, allocator) catch |err| {
                t.logErrorf("ntp runner failed: {}", .{err});
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            std.testing.allocator.destroy(self);
        }
    };

    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}

fn runImpl(comptime std: type, comptime Net: type, t: *testing_api.T, alloc: std.mem.Allocator) !void {
    _ = t;
    const Ntp = Net.ntp;
    const AddrPort = Net.netip.AddrPort;
    const Thread = std.Thread;
    const Context = context_mod.make(std, Net.time);
    const testing = struct {
        pub var allocator: std.mem.Allocator = undefined;
        pub const expect = std.testing.expect;
        pub const expectEqual = std.testing.expectEqual;
        pub const expectEqualStrings = std.testing.expectEqualStrings;
        pub const expectError = std.testing.expectError;
    };
    testing.allocator = alloc;

    const Runner = struct {
        fn addr4(port: u16) AddrPort {
            return AddrPort.from4(.{ 127, 0, 0, 1 }, port);
        }

        fn waitForTrue(flag: *std.atomic.Value(bool), timeout: Net.time.duration.Duration) !void {
            var waited: Net.time.duration.Duration = 0;
            while (waited < timeout) : (waited += Net.time.duration.MilliSecond) {
                if (flag.load(.acquire)) return;
                Thread.sleep(@intCast(Net.time.duration.MilliSecond));
            }
            return error.Timeout;
        }

        fn expectReasonableResponse(resp: Ntp.Response) !void {
            try testing.expect(resp.stratum >= 1 and resp.stratum <= 15);
            try testing.expect(resp.receive_time.unixMilli() > 1_700_000_000_000);
            try testing.expect(resp.transmit_time.unixMilli() > 1_700_000_000_000);
        }

        fn queryAliyun() !void {
            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{Ntp.Servers.aliyun},
                .timeout = 5000 * Net.time.duration.MilliSecond,
            });
            defer client.deinit();

            const t1 = Net.time.now();
            const resp = try client.query(t1);
            const t4 = Net.time.now();

            try expectReasonableResponse(resp);

            const offset = @divFloor(resp.receive_time.sub(t1) + resp.transmit_time.sub(t4), 2);
            try testing.expect(@abs(offset) < 300_000 * Net.time.duration.MilliSecond);
        }

        fn getTimeAliyun() !void {
            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{Ntp.Servers.aliyun},
                .timeout = 5000 * Net.time.duration.MilliSecond,
            });
            defer client.deinit();

            const current_time = try client.getTime(Net.time.now());
            const local_time = Net.time.now();

            try testing.expect(current_time.unixMilli() > 1_700_000_000_000);
            try testing.expect(@abs(current_time.sub(local_time)) < 300_000 * Net.time.duration.MilliSecond);
        }

        fn queryRaceWithAliyunAndBadEndpoint() !void {
            const bad = Ntp.Server.init(addr4(1));
            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{ bad, Ntp.Servers.aliyun },
                .timeout = 3000 * Net.time.duration.MilliSecond,
            });
            defer client.deinit();

            const resp = try client.queryRace(Net.time.now());
            try expectReasonableResponse(resp);
        }

        fn queryRaceWithDefaultServers() !void {
            var client = try Ntp.Client.init(testing.allocator, .{
                .timeout = 5000 * Net.time.duration.MilliSecond,
            });
            defer client.deinit();

            const resp = try client.queryRace(Net.time.now());
            try expectReasonableResponse(resp);
        }

        fn queryUsesRaceAcrossConfiguredServers() !void {
            const bad = Ntp.Server.init(addr4(1));
            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{ bad, Ntp.Servers.aliyun, Ntp.Servers.cloudflare },
                .timeout = 5000 * Net.time.duration.MilliSecond,
            });
            defer client.deinit();

            const resp = try client.query(Net.time.now());
            try expectReasonableResponse(resp);
        }

        fn queryContextCanceledBeforeStart() !void {
            var context_api = try Context.init(testing.allocator);
            defer context_api.deinit();

            var cancel_ctx = try context_api.withCancel(context_api.background());
            defer cancel_ctx.deinit();
            cancel_ctx.cancel();

            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{Ntp.Servers.aliyun},
                .timeout = 5000 * Net.time.duration.MilliSecond,
            });
            defer client.deinit();

            try testing.expectError(error.Canceled, client.queryContext(cancel_ctx, Net.time.now()));
        }

        fn queryRaceContextCanceledBeforeStart() !void {
            var context_api = try Context.init(testing.allocator);
            defer context_api.deinit();

            var cancel_ctx = try context_api.withCancel(context_api.background());
            defer cancel_ctx.deinit();
            cancel_ctx.cancel();

            const bad = Ntp.Server.init(addr4(1));
            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{ bad, Ntp.Servers.aliyun, Ntp.Servers.cloudflare },
                .timeout = 5000 * Net.time.duration.MilliSecond,
            });
            defer client.deinit();

            try testing.expectError(error.Canceled, client.queryContext(cancel_ctx, Net.time.now()));
        }

        fn queryRaceContextCancelStopsWorkersPromptly() !void {
            const BoolAtomic = std.atomic.Value(bool);

            var pc1 = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc1.deinit();
            var pc2 = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc2.deinit();

            const impl1 = try pc1.as(Net.UdpConn);
            const impl2 = try pc2.as(Net.UdpConn);

            var context_api = try Context.init(testing.allocator);
            defer context_api.deinit();
            var timeout_ctx = try context_api.withTimeout(context_api.background(), 5 * Net.time.duration.MilliSecond);
            defer timeout_ctx.deinit();

            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{
                    Ntp.Server.init(addr4(try impl1.boundPort())),
                    Ntp.Server.init(addr4(try impl2.boundPort())),
                },
                .timeout = 1000 * Net.time.duration.MilliSecond,
            });
            defer client.deinit();

            try testing.expectError(error.DeadlineExceeded, client.queryRaceContext(timeout_ctx, Net.time.now()));

            var wait_done = BoolAtomic.init(false);
            var wait_thread = try Thread.spawn(.{}, struct {
                fn run(c: *Ntp.Client, done: *BoolAtomic) void {
                    c.wait();
                    done.store(true, .release);
                }
            }.run, .{ &client, &wait_done });
            defer wait_thread.join();

            try waitForTrue(&wait_done, 300 * Net.time.duration.MilliSecond);
        }

        fn singleServerWaitBlocksUntilQueryCompletes() !void {
            const BoolAtomic = std.atomic.Value(bool);

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();
            var request_seen = BoolAtomic.init(false);
            var server_thread = try Thread.spawn(.{}, struct {
                fn run(server_pc: Net.PacketConn, seen: *BoolAtomic) void {
                    var req_buf: [128]u8 = undefined;
                    _ = server_pc.readFrom(&req_buf) catch return;
                    seen.store(true, .release);
                }
            }.run, .{ pc, &request_seen });
            defer server_thread.join();

            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{Ntp.Server.init(addr4(port))},
                .timeout = 200 * Net.time.duration.MilliSecond,
            });
            defer client.deinit();

            var query_done = BoolAtomic.init(false);
            var query_thread = try Thread.spawn(.{}, struct {
                fn run(c: *Ntp.Client, done: *BoolAtomic) void {
                    _ = c.query(Net.time.now()) catch {};
                    done.store(true, .release);
                }
            }.run, .{ &client, &query_done });
            defer query_thread.join();

            try waitForTrue(&request_seen, 100 * Net.time.duration.MilliSecond);

            var wait_done = BoolAtomic.init(false);
            var wait_thread = try Thread.spawn(.{}, struct {
                fn run(c: *Ntp.Client, done: *BoolAtomic) void {
                    c.wait();
                    done.store(true, .release);
                }
            }.run, .{ &client, &wait_done });
            defer wait_thread.join();

            Thread.sleep(@intCast(20 * Net.time.duration.MilliSecond));
            try testing.expect(!wait_done.load(.acquire));

            try waitForTrue(&query_done, 1000 * Net.time.duration.MilliSecond);
            try waitForTrue(&wait_done, 1000 * Net.time.duration.MilliSecond);
        }

        fn queryReturnsClosedAfterDeinitStarts() !void {
            const BoolAtomic = std.atomic.Value(bool);

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();
            var request_seen = BoolAtomic.init(false);
            var server_thread = try Thread.spawn(.{}, struct {
                fn run(server_pc: Net.PacketConn, seen: *BoolAtomic) void {
                    var req_buf: [128]u8 = undefined;
                    _ = server_pc.readFrom(&req_buf) catch return;
                    seen.store(true, .release);
                }
            }.run, .{ pc, &request_seen });
            defer server_thread.join();

            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{Ntp.Server.init(addr4(port))},
                .timeout = 200 * Net.time.duration.MilliSecond,
            });
            var client_owned = true;
            errdefer if (client_owned) client.deinit();

            var first_query_done = BoolAtomic.init(false);
            var first_query_thread = try Thread.spawn(.{}, struct {
                fn run(c: *Ntp.Client, done: *BoolAtomic) void {
                    _ = c.query(Net.time.now()) catch {};
                    done.store(true, .release);
                }
            }.run, .{ &client, &first_query_done });
            errdefer first_query_thread.join();

            try waitForTrue(&request_seen, 100 * Net.time.duration.MilliSecond);

            var deinit_done = BoolAtomic.init(false);
            var deinit_thread = try Thread.spawn(.{}, struct {
                fn run(c: *Ntp.Client, done: *BoolAtomic) void {
                    c.deinit();
                    done.store(true, .release);
                }
            }.run, .{ &client, &deinit_done });
            client_owned = false;
            errdefer deinit_thread.join();

            try waitUntilDeiniting(std, Net, &client, 1000 * Net.time.duration.MilliSecond);
            try testing.expectError(error.Closed, client.query(Net.time.now()));
            try testing.expect(!deinit_done.load(.acquire));

            try waitForTrue(&first_query_done, 1000 * Net.time.duration.MilliSecond);
            try waitForTrue(&deinit_done, 1000 * Net.time.duration.MilliSecond);
            first_query_thread.join();
            deinit_thread.join();
        }

        fn concurrentAliyunQueries() !void {
            const Shared = struct {
                mutex: Thread.Mutex = .{},
                success_count: usize = 0,
            };

            var shared = Shared{};
            var threads: [2]Thread = undefined;
            for (&threads) |*thread| {
                thread.* = try Thread.spawn(.{}, struct {
                    fn run(shared_state: *Shared, comptime NtpNs: type, comptime l: type, allocator: l.mem.Allocator) void {
                        var client = NtpNs.Client.init(allocator, .{
                            .servers = &.{NtpNs.Servers.aliyun},
                            .timeout = 5000 * Net.time.duration.MilliSecond,
                        }) catch return;
                        defer client.deinit();

                        const resp = client.query(Net.time.now()) catch return;
                        if (resp.stratum < 1 or resp.stratum > 15) return;
                        if (resp.transmit_time.unixMilli() <= 1_700_000_000_000) return;

                        shared_state.mutex.lock();
                        defer shared_state.mutex.unlock();
                        shared_state.success_count += 1;
                    }
                }.run, .{ &shared, Ntp, std, testing.allocator });
            }
            for (&threads) |*thread| thread.join();

            try testing.expectEqual(@as(usize, 2), shared.success_count);
        }
    };

    try Runner.queryAliyun();
    try Runner.getTimeAliyun();
    try Runner.queryRaceWithAliyunAndBadEndpoint();
    try Runner.queryRaceWithDefaultServers();
    try Runner.queryUsesRaceAcrossConfiguredServers();
    try Runner.queryContextCanceledBeforeStart();
    try Runner.queryRaceContextCanceledBeforeStart();
    try Runner.queryRaceContextCancelStopsWorkersPromptly();
    try Runner.singleServerWaitBlocksUntilQueryCompletes();
    try Runner.queryReturnsClosedAfterDeinitStarts();
    try Runner.concurrentAliyunQueries();
}

fn waitUntilDeiniting(comptime l: type, comptime Net: type, client: anytype, timeout: Net.time.duration.Duration) !void {
    var waited: Net.time.duration.Duration = 0;
    while (waited < timeout) : (waited += Net.time.duration.MilliSecond) {
        client.mutex.lock();
        const deiniting = client.deiniting;
        client.mutex.unlock();
        if (deiniting) return;
        l.Thread.sleep(@intCast(Net.time.duration.MilliSecond));
    }
    return error.Timeout;
}
