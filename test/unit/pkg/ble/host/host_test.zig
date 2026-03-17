const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const module = embed.pkg.ble.host.host_mod;
const TxPacket = module.TxPacket;
const Host = module.Host;
const runtime = embed.runtime;
const hci_mod = embed.pkg.ble.host.hci.hci;
const acl_mod = embed.pkg.ble.host.hci.acl;
const commands = embed.pkg.ble.host.hci.commands;
const events_mod = embed.pkg.ble.host.hci.events;
const l2cap_mod = embed.pkg.ble.host.l2cap.l2cap;
const att_mod = embed.pkg.ble.host.att.att;
const gap_mod = embed.pkg.ble.host.gap.gap;
const gatt_server = embed.pkg.ble.gatt.server;
const gatt_client = embed.pkg.ble.gatt.client;
const AclCredits = module.AclCredits;
const MockHci = module.MockHci;

test "Host start reads buffer size and initializes credits" {
    const Rt = runtime.std;
    const Mock = MockHci();

    var hci_driver = Mock{};
    hci_driver.injectInitSequence();

    const TestHost = Host(Rt, Mock, &.{});
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

    const TestHost = Host(Rt, Mock, &.{});
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

    const TestHost = Host(Rt, Mock, &.{});
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
