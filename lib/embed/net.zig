//! Network utilities — address types matching std.net shape.

const std = @import("std_re_export.zig");
const mem = @import("mem.zig");
const math = std.math;

pub const IPv4ParseError = error{ InvalidCharacter, InvalidEnd, Overflow, Incomplete, NonCanonical };
pub const IPv6ParseError = error{ InvalidCharacter, InvalidEnd, Overflow, Incomplete, InvalidIpv4Mapping };

pub fn Ip4Address(comptime posix: type) type {
    return extern struct {
        sa: posix.sockaddr.in,

        const Self = @This();

        pub fn init(addr: [4]u8, port: u16) Self {
            return .{
                .sa = .{
                    .port = mem.nativeToBig(u16, port),
                    .addr = @as(*align(1) const u32, @ptrCast(&addr)).*,
                },
            };
        }

        pub fn parse(buf: []const u8, port: u16) IPv4ParseError!Self {
            var octets: [4]u8 = undefined;
            var octet_idx: u8 = 0;
            var cur: u8 = 0;
            var digits: u8 = 0;
            for (buf) |c| {
                if (c == '.') {
                    if (digits == 0) return error.InvalidCharacter;
                    if (octet_idx == 3) return error.InvalidEnd;
                    octets[octet_idx] = cur;
                    octet_idx += 1;
                    cur = 0;
                    digits = 0;
                } else if (c >= '0' and c <= '9') {
                    cur = math.mul(u8, cur, 10) catch return error.Overflow;
                    cur = math.add(u8, cur, c - '0') catch return error.Overflow;
                    digits += 1;
                } else {
                    return error.InvalidCharacter;
                }
            }
            if (octet_idx == 3 and digits > 0) {
                octets[3] = cur;
                return Self.init(octets, port);
            }
            return error.Incomplete;
        }

        pub fn getPort(self: Self) u16 {
            return mem.bigToNative(u16, self.sa.port);
        }

        pub fn setPort(self: *Self, port: u16) void {
            self.sa.port = mem.nativeToBig(u16, port);
        }

        pub fn getOsSockLen(self: Self) posix.socklen_t {
            _ = self;
            return @sizeOf(posix.sockaddr.in);
        }
    };
}

pub fn Ip6Address(comptime posix: type) type {
    return extern struct {
        sa: posix.sockaddr.in6,

        const Self = @This();

        pub fn init(addr: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Self {
            return .{
                .sa = .{
                    .port = mem.nativeToBig(u16, port),
                    .flowinfo = flowinfo,
                    .addr = addr,
                    .scope_id = scope_id,
                },
            };
        }

        pub fn parse(buf: []const u8, port: u16) IPv6ParseError!Self {
            var result = Self{
                .sa = .{
                    .scope_id = 0,
                    .port = mem.nativeToBig(u16, port),
                    .flowinfo = 0,
                    .addr = undefined,
                },
            };
            var ip_slice: *[16]u8 = &result.sa.addr;
            var tail: [16]u8 = undefined;

            var x: u16 = 0;
            var saw_any_digits = false;
            var index: u8 = 0;
            var scope = false;
            var abbrv = false;

            for (buf, 0..) |c, i| {
                if (scope) {
                    if (c >= '0' and c <= '9') {
                        result.sa.scope_id = math.mul(u32, result.sa.scope_id, 10) catch return error.Overflow;
                        result.sa.scope_id = math.add(u32, result.sa.scope_id, c - '0') catch return error.Overflow;
                    } else {
                        return error.InvalidCharacter;
                    }
                } else if (c == ':') {
                    if (!saw_any_digits) {
                        if (abbrv) return error.InvalidCharacter;
                        if (i != 0) abbrv = true;
                        @memset(ip_slice[index..], 0);
                        ip_slice = &tail;
                        index = 0;
                        continue;
                    }
                    if (index == 14) return error.InvalidEnd;
                    ip_slice[index] = @truncate(x >> 8);
                    ip_slice[index + 1] = @truncate(x);
                    index += 2;
                    x = 0;
                    saw_any_digits = false;
                } else if (c == '%') {
                    if (!saw_any_digits) return error.InvalidCharacter;
                    scope = true;
                    saw_any_digits = false;
                } else if (c == '.') {
                    if (!abbrv or ip_slice[0] != 0xff or ip_slice[1] != 0xff)
                        return error.InvalidIpv4Mapping;
                    const start = (mem.lastIndexOfScalar(u8, buf[0..i], ':') orelse return error.InvalidCharacter) + 1;
                    const v4 = Ip4Address(posix).parse(buf[start..], 0) catch return error.InvalidIpv4Mapping;
                    const v4_bytes: [4]u8 = @bitCast(v4.sa.addr);
                    ip_slice = &result.sa.addr;
                    ip_slice[10] = 0xff;
                    ip_slice[11] = 0xff;
                    ip_slice[12] = v4_bytes[0];
                    ip_slice[13] = v4_bytes[1];
                    ip_slice[14] = v4_bytes[2];
                    ip_slice[15] = v4_bytes[3];
                    return result;
                } else {
                    const digit = hexDigit(c) orelse return error.InvalidCharacter;
                    x = math.mul(u16, x, 16) catch return error.Overflow;
                    x = math.add(u16, x, digit) catch return error.Overflow;
                    saw_any_digits = true;
                }
            }

            if (!saw_any_digits and !abbrv) return error.Incomplete;
            if (!abbrv and index < 14) return error.Incomplete;

            if (index == 14) {
                ip_slice[14] = @truncate(x >> 8);
                ip_slice[15] = @truncate(x);
                return result;
            } else {
                ip_slice[index] = @truncate(x >> 8);
                ip_slice[index + 1] = @truncate(x);
                index += 2;
                @memcpy(result.sa.addr[16 - index ..][0..index], ip_slice[0..index]);
                return result;
            }
        }

        pub fn getPort(self: Self) u16 {
            return mem.bigToNative(u16, self.sa.port);
        }

        pub fn setPort(self: *Self, port: u16) void {
            self.sa.port = mem.nativeToBig(u16, port);
        }

        pub fn getOsSockLen(self: Self) posix.socklen_t {
            _ = self;
            return @sizeOf(posix.sockaddr.in6);
        }
    };
}

pub fn Address(comptime posix: type) type {
    const V4 = Ip4Address(posix);
    const V6 = Ip6Address(posix);

    return extern union {
        any: posix.sockaddr,
        in: V4,
        in6: V6,

        const Self = @This();

        pub fn initIp4(addr: [4]u8, port: u16) Self {
            return .{ .in = V4.init(addr, port) };
        }

        pub fn initIp6(addr: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Self {
            return .{ .in6 = V6.init(addr, port, flowinfo, scope_id) };
        }

        pub fn parseIp4(buf: []const u8, port: u16) IPv4ParseError!Self {
            return .{ .in = try V4.parse(buf, port) };
        }

        pub fn parseIp6(buf: []const u8, port: u16) IPv6ParseError!Self {
            return .{ .in6 = try V6.parse(buf, port) };
        }

        pub fn parseIp(buf: []const u8, port: u16) !Self {
            if (parseIp4(buf, port)) |v4| return v4 else |_| {}
            if (parseIp6(buf, port)) |v6| return v6 else |_| {}
            return error.InvalidCharacter;
        }

        pub fn getPort(self: Self) u16 {
            return switch (self.any.family) {
                posix.AF.INET => self.in.getPort(),
                posix.AF.INET6 => self.in6.getPort(),
                else => unreachable,
            };
        }

        pub fn setPort(self: *Self, port: u16) void {
            switch (self.any.family) {
                posix.AF.INET => self.in.setPort(port),
                posix.AF.INET6 => self.in6.setPort(port),
                else => unreachable,
            }
        }

        pub fn getOsSockLen(self: Self) posix.socklen_t {
            return switch (self.any.family) {
                posix.AF.INET => self.in.getOsSockLen(),
                posix.AF.INET6 => self.in6.getOsSockLen(),
                else => unreachable,
            };
        }
    };
}

fn hexDigit(c: u8) ?u16 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

test "parse" {
    const posix = std.posix;
    const expect = std.testing.expectEqual;
    const V4 = Ip4Address(posix);
    const V6 = Ip6Address(posix);
    const Addr = Address(posix);

    const v4 = comptime V4.parse("127.0.0.1", 80) catch unreachable;
    try expect(@as(u16, 80), v4.getPort());

    const v6 = comptime V6.parse("::1", 443) catch unreachable;
    try expect(@as(u16, 443), v6.getPort());

    const a4 = comptime Addr.parseIp4("10.0.0.1", 22) catch unreachable;
    try expect(@as(u16, 22), a4.getPort());

    const a6 = comptime Addr.parseIp6("fe80::1", 0) catch unreachable;
    try expect(@as(u16, 0), a6.getPort());

    const auto4 = comptime Addr.parseIp("192.168.1.1", 8080) catch unreachable;
    try expect(@as(u16, 8080), auto4.getPort());

    const auto6 = comptime Addr.parseIp("::1", 9090) catch unreachable;
    try expect(@as(u16, 9090), auto6.getPort());
}
