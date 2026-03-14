const std = @import("std");
const testing = std.testing;
const module = @import("host.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const TxPacket = module.TxPacket;
const Host = module.Host;
const runtime = test_exports.runtime;
const hci_mod = test_exports.hci_mod;
const acl_mod = test_exports.acl_mod;
const commands = test_exports.commands;
const events_mod = test_exports.events_mod;
const l2cap_mod = test_exports.l2cap_mod;
const att_mod = test_exports.att_mod;
const gap_mod = test_exports.gap_mod;
const gatt_server = test_exports.gatt_server;
const gatt_client = test_exports.gatt_client;
const AclCredits = test_exports.AclCredits;
const MockHci = test_exports.MockHci;

test "Host start reads buffer size and initializes credits" {
    const Rt = runtime.std;
    const Mock = MockHci();

    var hci_driver = Mock{};
    hci_driver.injectInitSequence();

    const TestHost = Host(Rt.Mutex, Rt.Condition, Rt.Thread, Mock, &.{});
    var host = TestHost.init(&hci_driver, std.testing.allocator);
    defer host.deinit();

    try host.start(.{});
    std.Thread.sleep(10 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u16, 251), host.acl_max_len);
    try std.testing.expectEqual(@as(u16, 12), host.acl_max_slots);
    try std.testing.expectEqual(@as(u32, 12), host.getAclCredits());
    try std.testing.expectEqual(@as(u8, 0x52), host.bd_addr[0]);
    try std.testing.expectEqual(@as(u8, 0x11), host.bd_addr[2]);
    try std.testing.expect(hci_driver.written_count.load(.acquire) >= 5);

    host.stop();
}

test "Host writeLoop respects ACL credits" {
    const Rt = runtime.std;
    const Mock = MockHci();

    var hci_driver = Mock{};
    hci_driver.injectInitSequence();

    const TestHost = Host(Rt.Mutex, Rt.Condition, Rt.Thread, Mock, &.{});
    var host = TestHost.init(&hci_driver, std.testing.allocator);
    defer host.deinit();

    try host.start(.{});
    std.Thread.sleep(10 * std.time.ns_per_ms);

    const written_before = hci_driver.written_count.load(.acquire);

    try host.sendData(0x0040, l2cap_mod.CID_ATT, "test data");

    std.Thread.sleep(50 * std.time.ns_per_ms);

    const written_after = hci_driver.written_count.load(.acquire);
    try std.testing.expect(written_after > written_before);
    try std.testing.expect(host.getAclCredits() < 12);

    host.stop();
}

test "Host NCP event releases credits" {
    const Rt = runtime.std;
    const Mock = MockHci();

    var hci_driver = Mock{};
    hci_driver.injectInitSequence();

    const TestHost = Host(Rt.Mutex, Rt.Condition, Rt.Thread, Mock, &.{});
    var host = TestHost.init(&hci_driver, std.testing.allocator);
    defer host.deinit();

    try host.start(.{});
    std.Thread.sleep(10 * std.time.ns_per_ms);

    try host.sendData(0x0040, l2cap_mod.CID_ATT, "test");
    std.Thread.sleep(50 * std.time.ns_per_ms);
    const credits_after_send = host.getAclCredits();

    hci_driver.injectPacket(&[_]u8{
        @intFromEnum(hci_mod.PacketType.event),
        0x13,
        0x05,
        0x01,
        0x40,
        0x00,
        0x05,
        0x00,
    });

    std.Thread.sleep(200 * std.time.ns_per_ms);

    const credits_after_ncp = host.getAclCredits();
    try std.testing.expect(credits_after_ncp > credits_after_send);

    host.stop();
}
