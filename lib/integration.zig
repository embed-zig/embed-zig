//! integration — shared integration helpers and embed compatibility runners.
pub const logging = @import("embed").test_runner.logging;
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
const collections_runner = @import("integration/collections.zig");
const crypto_runner = @import("integration/crypto.zig");
const random_runner = @import("integration/random.zig");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();

            t.run("thread", thread_runner.make(lib));
            t.run("log", log_runner.make(lib));
            t.run("context", context_runner.make(lib));
            t.run("posix", posix_runner.make(lib));
            t.run("time", time_runner.make(lib));
            t.run("atomic", atomic_runner.make(lib));
            t.run("mem", mem_runner.make(lib));
            t.run("fmt", fmt_runner.make(lib));
            t.run("collections", collections_runner.make(lib));
            t.run("crypto", crypto_runner.make(lib));
            t.run("random", random_runner.make(lib));
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
    const net_mod = @import("net");
    const sync_mod = @import("sync");
    const Net = net_mod.make(embed_std_mod.std);

    const channel_tr = sync_mod.test_runner.channel.make(embed_std_mod.std, embed_std_mod.sync.Channel);
    const racer_tr = sync_mod.test_runner.racer.make(embed_std_mod.std);
    const runner = make(embed_std_mod.std);
    const fd_stream_tr = net_mod.test_runner.fd_stream.make(embed_std_mod.std);
    const fd_packet_tr = net_mod.test_runner.fd_packet.make(embed_std_mod.std);
    const tcp_tr = net_mod.test_runner.tcp.make(embed_std_mod.std);
    const udp_tr = net_mod.test_runner.udp.make(embed_std_mod.std);
    const resolver_tr = net_mod.test_runner.resolver.make(embed_std_mod.std);
    const resolver_dns_tr = net_mod.test_runner.resolver_dns.make(embed_std_mod.std, &.{
        Net.Resolver.dns.ali.v4_1,
        Net.Resolver.dns.ali.v4_2,
    }, "dns.alidns.com");
    const tls_tr = net_mod.test_runner.tls.make(embed_std_mod.std);
    const tls_dial_tr = net_mod.test_runner.tls_dial.make(embed_std_mod.std, "dns.alidns.com");
    const ntp_tr = net_mod.test_runner.ntp.make(embed_std_mod.std);
    const http_transport_tr = net_mod.test_runner.http_transport.make(embed_std_mod.std);
    const https_transport_tr = net_mod.test_runner.https_transport.make(embed_std_mod.std);

    var t = testing_mod.T.new(embed_std_mod.std, .embed);
    defer t.deinit();

    t.parallel();
    t.timeout(10 * embed_std_mod.std.time.ns_per_s);

    t.run("sync/channel", channel_tr);
    t.run("sync/racer", racer_tr);
    t.run("integration", runner);
    t.run("net/fd_stream", fd_stream_tr);
    t.run("net/fd_packet", fd_packet_tr);
    t.run("net/tcp", tcp_tr);
    t.run("net/udp", udp_tr);
    t.run("net/resolver", resolver_tr);
    t.run("net/resolver_dns", resolver_dns_tr);
    t.run("net/tls", tls_tr);
    t.run("net/tls_dial", tls_dial_tr);
    t.run("net/ntp", ntp_tr);
    t.run("net/http_transport", http_transport_tr);
    t.run("net/https_transport", https_transport_tr);
    if (!t.wait()) return error.TestFailed;
}

test "integration_tests/std" {
    const std = @import("std");
    std.testing.log_level = .info;

    const net_mod = @import("net");
    const sync_mod = @import("sync");
    const Net = net_mod.make(std);

    const racer_tr = sync_mod.test_runner.racer.make(std);
    const runner = make(std);
    const fd_stream_tr = net_mod.test_runner.fd_stream.make(std);
    const fd_packet_tr = net_mod.test_runner.fd_packet.make(std);
    const tcp_tr = net_mod.test_runner.tcp.make(std);
    const udp_tr = net_mod.test_runner.udp.make(std);
    const resolver_tr = net_mod.test_runner.resolver.make(std);
    const resolver_dns_tr = net_mod.test_runner.resolver_dns.make(std, &.{
        Net.Resolver.dns.ali.v4_1,
        Net.Resolver.dns.ali.v4_2,
    }, "dns.alidns.com");
    const tls_tr = net_mod.test_runner.tls.make(std);
    const tls_dial_tr = net_mod.test_runner.tls_dial.make(std, "dns.alidns.com");
    const ntp_tr = net_mod.test_runner.ntp.make(std);
    const http_transport_tr = net_mod.test_runner.http_transport.make(std);
    const https_transport_tr = net_mod.test_runner.https_transport.make(std);

    var t = testing_mod.T.new(std, .std);
    defer t.deinit();

    t.parallel();
    t.timeout(10 * std.time.ns_per_s);

    t.run("sync/racer", racer_tr);
    t.run("integration", runner);
    t.run("net/fd_stream", fd_stream_tr);
    t.run("net/fd_packet", fd_packet_tr);
    t.run("net/tcp", tcp_tr);
    t.run("net/udp", udp_tr);
    t.run("net/resolver", resolver_tr);
    t.run("net/resolver_dns", resolver_dns_tr);
    t.run("net/tls", tls_tr);
    t.run("net/tls_dial", tls_dial_tr);
    t.run("net/ntp", ntp_tr);
    t.run("net/http_transport", http_transport_tr);
    t.run("net/https_transport", https_transport_tr);
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
