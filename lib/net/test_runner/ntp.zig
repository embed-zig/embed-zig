//! NTP test runner — public-network integration tests.
//!
//! These tests hit public Aliyun NTP directly, so they are intended for
//! environments with real network connectivity.
//!
//! Usage:
//!   const runner = @import("net/test_runner/ntp.zig").make(lib);
//!   t.run("net/ntp", runner);

const context_mod = @import("context");
const embed = @import("embed");
const net_mod = @import("../../net.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            runImpl(lib, t, allocator) catch |err| {
                t.logErrorf("ntp runner failed: {}", .{err});
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}

fn runImpl(comptime lib: type, t: *testing_api.T, alloc: lib.mem.Allocator) !void {
    _ = t;
    const Net = net_mod.make(lib);
    const Ntp = Net.ntp;
    const AddrPort = net_mod.netip.AddrPort;
    const Thread = lib.Thread;
    const Context = context_mod.make(lib);
    const testing = struct {
        pub var allocator: lib.mem.Allocator = undefined;
        pub const expect = lib.testing.expect;
        pub const expectEqual = lib.testing.expectEqual;
        pub const expectEqualStrings = lib.testing.expectEqualStrings;
        pub const expectError = lib.testing.expectError;
    };
    testing.allocator = alloc;

    const Runner = struct {
        fn addr4(port: u16) AddrPort {
            return AddrPort.from4(.{ 127, 0, 0, 1 }, port);
        }

        fn waitForTrue(flag: *lib.atomic.Value(bool), timeout_ms: u32) !void {
            var waited_ms: u32 = 0;
            while (waited_ms < timeout_ms) : (waited_ms += 1) {
                if (flag.load(.acquire)) return;
                Thread.sleep(lib.time.ns_per_ms);
            }
            return error.Timeout;
        }

        fn expectReasonableResponse(resp: Ntp.Response) !void {
            try testing.expect(resp.stratum >= 1 and resp.stratum <= 15);
            try testing.expect(resp.receive_time_ms > 1_700_000_000_000);
            try testing.expect(resp.transmit_time_ms > 1_700_000_000_000);
        }

        fn queryAliyun() !void {
            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{Ntp.Servers.aliyun},
                .timeout_ms = 5000,
            });
            defer client.deinit();

            const t1 = lib.time.milliTimestamp();
            const resp = try client.query(t1);
            const t4 = lib.time.milliTimestamp();

            try expectReasonableResponse(resp);

            const offset = @divFloor(
                (resp.receive_time_ms - t1) + (resp.transmit_time_ms - t4),
                2,
            );
            try testing.expect(@abs(offset) < 300_000);
        }

        fn getTimeAliyun() !void {
            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{Ntp.Servers.aliyun},
                .timeout_ms = 5000,
            });
            defer client.deinit();

            const current_time_ms = try client.getTime(lib.time.milliTimestamp());
            const local_time_ms = lib.time.milliTimestamp();

            try testing.expect(current_time_ms > 1_700_000_000_000);
            try testing.expect(@abs(current_time_ms - local_time_ms) < 300_000);
        }

        fn queryRaceWithAliyunAndBadEndpoint() !void {
            const bad = Ntp.Server.init(addr4(1));
            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{ bad, Ntp.Servers.aliyun },
                .timeout_ms = 3000,
            });
            defer client.deinit();

            const resp = try client.queryRace(lib.time.milliTimestamp());
            try expectReasonableResponse(resp);
        }

        fn queryRaceWithDefaultServers() !void {
            var client = try Ntp.Client.init(testing.allocator, .{
                .timeout_ms = 5000,
            });
            defer client.deinit();

            const resp = try client.queryRace(lib.time.milliTimestamp());
            try expectReasonableResponse(resp);
        }

        fn queryUsesRaceAcrossConfiguredServers() !void {
            const bad = Ntp.Server.init(addr4(1));
            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{ bad, Ntp.Servers.aliyun, Ntp.Servers.cloudflare },
                .timeout_ms = 5000,
            });
            defer client.deinit();

            const resp = try client.query(lib.time.milliTimestamp());
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
                .timeout_ms = 5000,
            });
            defer client.deinit();

            try testing.expectError(error.Canceled, client.queryContext(cancel_ctx, lib.time.milliTimestamp()));
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
                .timeout_ms = 5000,
            });
            defer client.deinit();

            try testing.expectError(error.Canceled, client.queryContext(cancel_ctx, lib.time.milliTimestamp()));
        }

        fn queryRaceContextCancelStopsWorkersPromptly() !void {
            const BoolAtomic = lib.atomic.Value(bool);

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
            var timeout_ctx = try context_api.withTimeout(context_api.background(), 5 * lib.time.ns_per_ms);
            defer timeout_ctx.deinit();

            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{
                    Ntp.Server.init(addr4(try impl1.boundPort())),
                    Ntp.Server.init(addr4(try impl2.boundPort())),
                },
                .timeout_ms = 1000,
            });
            defer client.deinit();

            try testing.expectError(error.DeadlineExceeded, client.queryRaceContext(timeout_ctx, lib.time.milliTimestamp()));

            var wait_done = BoolAtomic.init(false);
            var wait_thread = try Thread.spawn(.{}, struct {
                fn run(c: *Ntp.Client, done: *BoolAtomic) void {
                    c.wait();
                    done.store(true, .release);
                }
            }.run, .{ &client, &wait_done });
            defer wait_thread.join();

            try waitForTrue(&wait_done, 300);
        }

        fn singleServerWaitBlocksUntilQueryCompletes() !void {
            const BoolAtomic = lib.atomic.Value(bool);

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();
            var request_seen = BoolAtomic.init(false);
            var server_thread = try Thread.spawn(.{}, struct {
                fn run(server_pc: net_mod.PacketConn, seen: *BoolAtomic) void {
                    var req_buf: [128]u8 = undefined;
                    _ = server_pc.readFrom(&req_buf) catch return;
                    seen.store(true, .release);
                }
            }.run, .{ pc, &request_seen });
            defer server_thread.join();

            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{Ntp.Server.init(addr4(port))},
                .timeout_ms = 200,
            });
            defer client.deinit();

            var query_done = BoolAtomic.init(false);
            var query_thread = try Thread.spawn(.{}, struct {
                fn run(c: *Ntp.Client, done: *BoolAtomic) void {
                    _ = c.query(lib.time.milliTimestamp()) catch {};
                    done.store(true, .release);
                }
            }.run, .{ &client, &query_done });
            defer query_thread.join();

            try waitForTrue(&request_seen, 100);

            var wait_done = BoolAtomic.init(false);
            var wait_thread = try Thread.spawn(.{}, struct {
                fn run(c: *Ntp.Client, done: *BoolAtomic) void {
                    c.wait();
                    done.store(true, .release);
                }
            }.run, .{ &client, &wait_done });
            defer wait_thread.join();

            Thread.sleep(20 * lib.time.ns_per_ms);
            try testing.expect(!wait_done.load(.acquire));

            try waitForTrue(&query_done, 1000);
            try waitForTrue(&wait_done, 1000);
        }

        fn queryReturnsClosedAfterDeinitStarts() !void {
            const BoolAtomic = lib.atomic.Value(bool);

            var pc = try Net.listenPacket(.{
                .allocator = testing.allocator,
                .address = addr4(0),
            });
            defer pc.deinit();

            const impl = try pc.as(Net.UdpConn);
            const port = try impl.boundPort();
            var request_seen = BoolAtomic.init(false);
            var server_thread = try Thread.spawn(.{}, struct {
                fn run(server_pc: net_mod.PacketConn, seen: *BoolAtomic) void {
                    var req_buf: [128]u8 = undefined;
                    _ = server_pc.readFrom(&req_buf) catch return;
                    seen.store(true, .release);
                }
            }.run, .{ pc, &request_seen });
            defer server_thread.join();

            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{Ntp.Server.init(addr4(port))},
                .timeout_ms = 200,
            });
            var client_owned = true;
            errdefer if (client_owned) client.deinit();

            var first_query_done = BoolAtomic.init(false);
            var first_query_thread = try Thread.spawn(.{}, struct {
                fn run(c: *Ntp.Client, done: *BoolAtomic) void {
                    _ = c.query(lib.time.milliTimestamp()) catch {};
                    done.store(true, .release);
                }
            }.run, .{ &client, &first_query_done });
            errdefer first_query_thread.join();

            try waitForTrue(&request_seen, 100);

            var deinit_done = BoolAtomic.init(false);
            var deinit_thread = try Thread.spawn(.{}, struct {
                fn run(c: *Ntp.Client, done: *BoolAtomic) void {
                    c.deinit();
                    done.store(true, .release);
                }
            }.run, .{ &client, &deinit_done });
            client_owned = false;
            errdefer deinit_thread.join();

            try waitUntilDeiniting(lib, &client, 1000);
            try testing.expectError(error.Closed, client.query(lib.time.milliTimestamp()));
            try testing.expect(!deinit_done.load(.acquire));

            try waitForTrue(&first_query_done, 1000);
            try waitForTrue(&deinit_done, 1000);
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
                            .timeout_ms = 5000,
                        }) catch return;
                        defer client.deinit();

                        const resp = client.query(l.time.milliTimestamp()) catch return;
                        if (resp.stratum < 1 or resp.stratum > 15) return;
                        if (resp.transmit_time_ms <= 1_700_000_000_000) return;

                        shared_state.mutex.lock();
                        defer shared_state.mutex.unlock();
                        shared_state.success_count += 1;
                    }
                }.run, .{ &shared, Ntp, lib, testing.allocator });
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

fn waitUntilDeiniting(comptime l: type, client: anytype, timeout_ms: u32) !void {
    var waited_ms: u32 = 0;
    while (waited_ms < timeout_ms) : (waited_ms += 1) {
        client.mutex.lock();
        const deiniting = client.deiniting;
        client.mutex.unlock();
        if (deiniting) return;
        l.Thread.sleep(l.time.ns_per_ms);
    }
    return error.Timeout;
}
