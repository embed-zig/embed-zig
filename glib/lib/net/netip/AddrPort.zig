const Addr = @import("Addr.zig");
const testing_api = @import("testing");

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

pub fn TestRunner(comptime std: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(std, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, _: std.mem.Allocator) !void {
            const testing = std.testing;

            const ap = AddrPort.from4(.{ 127, 0, 0, 1 }, 8080);
            try testing.expect(ap.isValid());
            try testing.expectEqual(@as(u16, 8080), ap.port());
            try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &ap.addr().as4().?);

            const base = AddrPort.init(try Addr.parse("::1"), 80);
            const next = base.withPort(443);
            try testing.expectEqual(@as(u16, 80), base.port());
            try testing.expectEqual(@as(u16, 443), next.port());
            try testing.expect(next.addr().is6());
        }
    }.run);
}
