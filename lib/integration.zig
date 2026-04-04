//! integration — shared integration helpers and embed compatibility runners.
const embed = @import("embed");
const testing_mod = @import("testing");

const thread_runner = @import("integration/thread.zig");
const log_runner = @import("integration/log.zig");
const context_runner = @import("integration/context.zig");
const posix_runner = @import("integration/posix.zig");
const time_runner = @import("integration/time.zig");
const atomic_runner = @import("integration/atomic.zig");
const mem_runner = @import("integration/mem.zig");
const fmt_runner = @import("integration/fmt.zig");
const json_runner = @import("integration/json.zig");
const collections_runner = @import("integration/collections.zig");
const crypto_runner = @import("integration/crypto.zig");
const random_runner = @import("integration/random.zig");

pub fn make(comptime lib: type, comptime ChannelFactory: fn (type) type) testing_mod.TestRunner {
    const audio_mod = @import("audio");
    const net_mod = @import("net");
    const sync_mod = @import("sync");
    const Net = net_mod.make(lib);
    const Channel = sync_mod.Channel(ChannelFactory);

    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();

            t.run("std/thread", thread_runner.make(lib));
            t.run("std/log", log_runner.make(lib));
            t.run("std/context", context_runner.make(lib));
            t.run("std/posix", posix_runner.make(lib));
            t.run("std/time", time_runner.make(lib));
            t.run("std/atomic", atomic_runner.make(lib));
            t.run("std/mem", mem_runner.make(lib));
            t.run("std/fmt", fmt_runner.make(lib));
            t.run("std/json", json_runner.make(lib));
            t.run("std/collections", collections_runner.make(lib));
            t.run("std/crypto", crypto_runner.make(lib));
            t.run("std/random", random_runner.make(lib));
            t.run("sync/channel", sync_mod.test_runner.channel.make(lib, Channel));
            t.run("sync/racer", sync_mod.test_runner.racer.make(lib));
            t.run("audio/mixer", audio_mod.test_runner.mixer.make(lib));
            t.run("net/fd_stream", net_mod.test_runner.fd_stream.make(lib));
            t.run("net/fd_packet", net_mod.test_runner.fd_packet.make(lib));
            t.run("net/tcp", net_mod.test_runner.tcp.make(lib));
            t.run("net/udp", net_mod.test_runner.udp.make(lib));
            t.run("net/resolver", net_mod.test_runner.resolver.make(lib));
            t.run("net/resolver_dns", net_mod.test_runner.resolver_dns.make(lib, &.{
                Net.Resolver.dns.ali.v4_1,
                Net.Resolver.dns.ali.v4_2,
            }, "dns.alidns.com"));
            t.run("net/tls", net_mod.test_runner.tls.make(lib));
            t.run("net/tls_dial", net_mod.test_runner.tls_dial.make(lib, "dns.alidns.com"));
            t.run("net/ntp", net_mod.test_runner.ntp.make(lib));
            t.run("net/http_client", net_mod.test_runner.http_client.make(lib));
            t.run("net/http_server", net_mod.test_runner.http_server.make(lib));
            t.run("net/http_transport", net_mod.test_runner.http_transport.make(lib));
            t.run("net/https_transport", net_mod.test_runner.https_transport.make(lib));
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_mod.TestRunner.make(Runner).new(runner);
}

test "integration_tests/embed" {
    const std = @import("std");
    std.testing.log_level = .info;

    const embed_std_mod = @import("embed_std");
    const runner = make(embed_std_mod.std, embed_std_mod.sync.ChannelFactory(embed_std_mod.std));

    var t = testing_mod.T.new(embed_std_mod.std, .embed);
    defer t.deinit();

    t.parallel();
    t.timeout(10 * embed_std_mod.std.time.ns_per_s);

    t.run("integration", runner);
    if (!t.wait()) return error.TestFailed;
}

test "integration_tests/std" {
    const std = @import("std");
    std.testing.log_level = .info;

    const embed_std_mod = @import("embed_std");
    const runner = make(std, embed_std_mod.sync.ChannelFactory(std));

    var t = testing_mod.T.new(std, .std);
    defer t.deinit();

    t.parallel();
    t.timeout(10 * std.time.ns_per_s);

    t.run("integration", runner);
    if (!t.wait()) return error.TestFailed;
}

test "integration_tests/context/lifecycle/root_tracks_active_child_until_child_deinit" {
    const std = @import("std");
    const context_mod = @import("context");

    const Ctx = context_mod.make(std);
    var ctx_ns = try Ctx.init(std.testing.allocator);
    const bg = ctx_ns.background();
    var child = try ctx_ns.withCancel(bg);

    // Root deinit is only valid once the tree is empty, so the integration
    // test checks the observable state instead of exercising a fatal path.
    try std.testing.expect(ctx_ns.shared.background_impl.tree.children.first != null);

    child.deinit();
    try std.testing.expect(ctx_ns.shared.background_impl.tree.children.first == null);

    ctx_ns.deinit();
}

test "integration_tests/context/lifecycle/deinit_parent_reparents_live_child_to_root" {
    const std = @import("std");
    const context_mod = @import("context");

    const Ctx = context_mod.make(std);
    var ctx_ns = try Ctx.init(std.testing.allocator);
    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    var child = try ctx_ns.withCancel(parent);

    parent.deinit();

    const ChildImpl = Ctx.CancelContext;
    const child_impl = try child.as(ChildImpl);
    try std.testing.expect(child_impl.tree.parent != null);
    try std.testing.expect(child_impl.tree.parent.?.ptr == bg.ptr);
    try std.testing.expect(child_impl.tree.parent.?.vtable == bg.vtable);
    try std.testing.expect(ctx_ns.shared.background_impl.tree.children.first != null);

    child.deinit();
    try std.testing.expect(ctx_ns.shared.background_impl.tree.children.first == null);

    ctx_ns.deinit();
}

test "integration_tests/bt/central" {
    const std = @import("std");
    std.testing.log_level = .info;

    const bt_mod = @import("bt");
    const Mocker = bt_mod.Mocker(std);

    var mocker = Mocker.init(std.testing.allocator, .{});
    defer mocker.deinit();

    var host = try mocker.createHost(.{});
    defer host.deinit();

    var t = testing_mod.T.new(std, .bt_central);
    defer t.deinit();

    t.run("central", bt_mod.test_runner.central.make(std, &host));
    if (!t.wait()) return error.TestFailed;
}

test "integration_tests/bt/peripheral" {
    const std = @import("std");
    std.testing.log_level = .info;

    const bt_mod = @import("bt");
    const Mocker = bt_mod.Mocker(std);

    var mocker = Mocker.init(std.testing.allocator, .{});
    defer mocker.deinit();

    var host = try mocker.createHost(.{});
    defer host.deinit();

    var t = testing_mod.T.new(std, .bt_peripheral);
    defer t.deinit();
    t.timeout(5 * std.time.ns_per_s);

    t.run("peripheral", bt_mod.test_runner.peripheral.make(std, &host));
    if (!t.wait()) return error.TestFailed;
}

test "integration_tests/bt/pair" {
    const std = @import("std");
    std.testing.log_level = .info;

    const bt_mod = @import("bt");
    const Mocker = bt_mod.Mocker(std);

    var mocker = Mocker.init(std.testing.allocator, .{});
    defer mocker.deinit();

    var host_a = try mocker.createHost(.{
        .position = .{ .x = -1, .y = 0, .z = 0 },
    });
    defer host_a.deinit();

    var host_b = try mocker.createHost(.{
        .position = .{ .x = 1, .y = 0, .z = 0 },
        .hci = .{
            .controller_addr = .{ 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6 },
            .peer_addr = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
        },
    });
    defer host_b.deinit();

    var t = testing_mod.T.new(std, .bt_pair);
    defer t.deinit();

    t.timeout(5 * std.time.ns_per_s);

    t.parallel();
    t.run("a/peripheral", bt_mod.test_runner.pair.makePeripheral(std, &host_a));
    t.run("b/peripheral", bt_mod.test_runner.pair.makePeripheral(std, &host_b));
    t.run("a/central", bt_mod.test_runner.pair.makeCentral(std, &host_a));
    t.run("b/central", bt_mod.test_runner.pair.makeCentral(std, &host_b));

    if (!t.wait()) return error.TestFailed;
}

test "integration_tests/bt/xfer" {
    const std = @import("std");
    std.testing.log_level = .info;

    const bt_mod = @import("bt");
    const Bt = bt_mod.make(std, @import("embed_std").sync.Channel);
    const Mocker = bt_mod.Mocker(std);

    var mocker = Mocker.init(std.testing.allocator, .{});
    defer mocker.deinit();

    var client_host = try mocker.createHost(.{
        .position = .{ .x = -1, .y = 0, .z = 0 },
    });
    defer client_host.deinit();

    var server_host = try mocker.createHost(.{
        .position = .{ .x = 1, .y = 0, .z = 0 },
        .hci = .{
            .controller_addr = .{ 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6 },
            .peer_addr = .{ 0x51, 0x52, 0x53, 0x54, 0x55, 0x56 },
            .mtu = 64,
        },
    });
    defer server_host.deinit();

    var t = testing_mod.T.new(std, .bt_xfer);
    defer t.deinit();
    t.timeout(5 * std.time.ns_per_s);

    t.parallel();
    t.run("xfer/peripheral", bt_mod.test_runner.pair_xfer.makePeripheral(std, Bt.Server, &server_host));
    t.run("xfer/central", bt_mod.test_runner.pair_xfer.makeCentral(std, Bt.Client, &client_host));
    if (!t.wait()) return error.TestFailed;
}
