const Addr = @import("Addr.zig");

const AddrPort = @This();

addr_: Addr = .{},
port_: u16 = 0,

pub fn init(ip: Addr, p: u16) AddrPort {
    return .{
        .addr_ = ip,
        .port_ = p,
    };
}

pub fn from4(v: [4]u8, p: u16) AddrPort {
    return init(Addr.from4(v), p);
}

pub fn from16(v: [16]u8, p: u16) AddrPort {
    return init(Addr.from16(v), p);
}

pub fn addr(self: AddrPort) Addr {
    return self.addr_;
}

pub fn port(self: AddrPort) u16 {
    return self.port_;
}

pub fn withPort(self: AddrPort, p: u16) AddrPort {
    return .{
        .addr_ = self.addr_,
        .port_ = p,
    };
}

pub fn isValid(self: AddrPort) bool {
    return self.addr_.isValid();
}

test "net/unit_tests/netip/addrport/init" {
    const testing = @import("std").testing;

    const ap = AddrPort.from4(.{ 127, 0, 0, 1 }, 8080);
    try testing.expect(ap.isValid());
    try testing.expectEqual(@as(u16, 8080), ap.port());
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &ap.addr().as4().?);
}

test "net/unit_tests/netip/addrport/withPort" {
    const testing = @import("std").testing;

    const base = AddrPort.init(try Addr.parse("::1"), 80);
    const next = base.withPort(443);
    try testing.expectEqual(@as(u16, 80), base.port());
    try testing.expectEqual(@as(u16, 443), next.port());
    try testing.expect(next.addr().is6());
}
