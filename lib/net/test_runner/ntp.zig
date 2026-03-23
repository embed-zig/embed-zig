//! NTP test runner — public-network integration tests.
//!
//! These tests hit public Aliyun NTP directly, so they are intended for
//! environments with real network connectivity.
//!
//! Usage:
//!   try @import("net/test_runner/ntp.zig").run(lib);

const context_mod = @import("context");
const net_mod = @import("../../net.zig");

pub fn run(comptime lib: type) !void {
    const Net = net_mod.Make(lib);
    const Ntp = Net.ntp;
    const Addr = lib.net.Address;
    const Thread = lib.Thread;
    const testing = lib.testing;
    const log = lib.log.scoped(.ntp);
    const Context = context_mod.Make(lib);

    const Runner = struct {
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
            const bad = Ntp.Server.init(Addr.initIp4(.{ 127, 0, 0, 1 }, 1));
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
            const bad = Ntp.Server.init(Addr.initIp4(.{ 127, 0, 0, 1 }, 1));
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

            const bad = Ntp.Server.init(Addr.initIp4(.{ 127, 0, 0, 1 }, 1));
            var client = try Ntp.Client.init(testing.allocator, .{
                .servers = &.{ bad, Ntp.Servers.aliyun, Ntp.Servers.cloudflare },
                .timeout_ms = 5000,
            });
            defer client.deinit();

            try testing.expectError(error.Canceled, client.queryContext(cancel_ctx, lib.time.milliTimestamp()));
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

    log.info("=== ntp test_runner start ===", .{});
    try Runner.queryAliyun();
    try Runner.getTimeAliyun();
    try Runner.queryRaceWithAliyunAndBadEndpoint();
    try Runner.queryRaceWithDefaultServers();
    try Runner.queryUsesRaceAcrossConfiguredServers();
    try Runner.queryContextCanceledBeforeStart();
    try Runner.queryRaceContextCanceledBeforeStart();
    try Runner.concurrentAliyunQueries();
    log.info("=== ntp test_runner done ===", .{});
}
