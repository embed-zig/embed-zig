const std = @import("std");
const testing = std.testing;
const module = @import("netif.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Ipv4Address = module.Ipv4Address;
const MacAddress = module.MacAddress;
const IfName = module.IfName;
const State = module.State;
const DhcpMode = module.DhcpMode;
const types = module.types;
const Info = module.Info;
const Route = module.Route;
const from = module.from;
const ifName = module.ifName;

test "ifName helper" {
    const n = ifName("sta");
    try std.testing.expectEqual(@as(u8, 's'), n[0]);
    try std.testing.expectEqual(@as(u8, 't'), n[1]);
    try std.testing.expectEqual(@as(u8, 'a'), n[2]);
}
