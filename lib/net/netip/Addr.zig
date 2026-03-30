const embed = @import("embed");

const debug = embed.debug;
const fmt = embed.fmt;
const math = embed.math;
const mem = embed.mem;

const Addr = @This();

pub const max_zone_len: usize = 32;

pub const ParseError = error{
    InvalidCharacter,
    InvalidEnd,
    Overflow,
    Incomplete,
    NonCanonical,
    InvalidIpv4Mapping,
    ZoneTooLong,
    ZoneOnIPv4,
};

const Kind = enum(u2) {
    invalid,
    v4,
    v6,
};

const v4_in_v6_prefix = [12]u8{
    0, 0, 0, 0, 0,    0,
    0, 0, 0, 0, 0xff, 0xff,
};

bytes: [16]u8 = [_]u8{0} ** 16,
zone: [max_zone_len]u8 = [_]u8{0} ** max_zone_len,
zone_len: u8 = 0,
kind: Kind = .invalid,

pub fn parse(s: []const u8) ParseError!Addr {
    if (s.len == 0) return error.Incomplete;

    if (mem.indexOfScalar(u8, s, '%')) |percent| {
        if (percent == 0 or percent + 1 >= s.len) return error.InvalidCharacter;
        const zone = s[percent + 1 ..];
        if (zone.len > max_zone_len) return error.ZoneTooLong;
        if (parseIpv4(s[0..percent])) |_| return error.ZoneOnIPv4 else |_| {}

        var addr = try parseIpv6(s[0..percent]);
        @memcpy(addr.zone[0..zone.len], zone);
        addr.zone_len = @intCast(zone.len);
        return addr;
    }

    return parseIpv4(s) catch try parseIpv6(s);
}

pub fn mustParse(comptime s: []const u8) Addr {
    return parse(s) catch @compileError("invalid netip.Addr literal: " ++ s);
}

pub fn from4(v: [4]u8) Addr {
    var out = Addr{};
    out.kind = .v4;
    @memcpy(out.bytes[12..16], &v);
    return out;
}

pub fn from16(v: [16]u8) Addr {
    return .{
        .bytes = v,
        .kind = .v6,
    };
}

pub fn isValid(self: Addr) bool {
    return self.kind != .invalid;
}

pub fn is4(self: Addr) bool {
    return self.kind == .v4;
}

pub fn is4In6(self: Addr) bool {
    return self.kind == .v6 and mem.eql(u8, self.bytes[0..12], &v4_in_v6_prefix);
}

pub fn is6(self: Addr) bool {
    return self.kind == .v6;
}

pub fn as4(self: Addr) ?[4]u8 {
    if (self.kind == .v4 or self.is4In6()) return self.bytes[12..16].*;
    return null;
}

pub fn as16(self: Addr) ?[16]u8 {
    return switch (self.kind) {
        .invalid => null,
        .v4 => blk: {
            var out = [_]u8{0} ** 16;
            @memcpy(out[0..12], &v4_in_v6_prefix);
            @memcpy(out[12..16], self.bytes[12..16]);
            break :blk out;
        },
        .v6 => self.bytes,
    };
}

pub fn unmap(self: Addr) Addr {
    if (self.is4In6()) return from4(self.bytes[12..16].*);
    return self;
}

pub fn bitLen(self: Addr) u8 {
    return switch (self.kind) {
        .invalid => 0,
        .v4 => 32,
        .v6 => 128,
    };
}

pub fn compare(a: Addr, b: Addr) math.Order {
    const a_bits = a.bitLen();
    const b_bits = b.bitLen();
    if (a_bits < b_bits) return .lt;
    if (a_bits > b_bits) return .gt;

    const cmp = switch (a.kind) {
        .invalid => math.Order.eq,
        .v4 => mem.order(u8, a.bytes[12..16], b.bytes[12..16]),
        .v6 => mem.order(u8, &a.bytes, &b.bytes),
    };
    if (cmp != .eq) return cmp;

    if (a.kind != .v6) return .eq;
    return compareZones(a.zone[0..a.zone_len], b.zone[0..b.zone_len]);
}

pub fn less(a: Addr, b: Addr) bool {
    return compare(a, b) == .lt;
}

pub fn isLoopback(self: Addr) bool {
    return switch (self.kind) {
        .invalid => false,
        .v4 => self.bytes[12] == 127,
        .v6 => blk: {
            const loopback = [_]u8{0} ** 15 ++ [_]u8{1};
            break :blk mem.eql(u8, &self.bytes, &loopback);
        },
    };
}

pub fn isPrivate(self: Addr) bool {
    return switch (self.kind) {
        .invalid => false,
        .v4 => blk: {
            const b = self.bytes[12..16];
            break :blk b[0] == 10 or
                (b[0] == 172 and b[1] >= 16 and b[1] <= 31) or
                (b[0] == 192 and b[1] == 168);
        },
        .v6 => (self.bytes[0] & 0xfe) == 0xfc,
    };
}

pub fn isMulticast(self: Addr) bool {
    return switch (self.kind) {
        .invalid => false,
        .v4 => (self.bytes[12] & 0xf0) == 0xe0,
        .v6 => self.bytes[0] == 0xff,
    };
}

pub fn isLinkLocalUnicast(self: Addr) bool {
    return switch (self.kind) {
        .invalid => false,
        .v4 => self.bytes[12] == 169 and self.bytes[13] == 254,
        .v6 => self.bytes[0] == 0xfe and (self.bytes[1] & 0xc0) == 0x80,
    };
}

pub fn isLinkLocalMulticast(self: Addr) bool {
    return switch (self.kind) {
        .invalid => false,
        .v4 => self.bytes[12] == 224 and self.bytes[13] == 0 and self.bytes[14] == 0,
        .v6 => self.bytes[0] == 0xff and (self.bytes[1] & 0x0f) == 0x02,
    };
}

pub fn isGlobalUnicast(self: Addr) bool {
    if (!self.isValid()) return false;
    if (self.isUnspecified()) return false;
    if (self.isLoopback()) return false;
    if (self.isMulticast()) return false;
    if (self.isLinkLocalUnicast()) return false;
    if (self.kind == .v4 and mem.eql(u8, self.bytes[12..16], &[_]u8{ 255, 255, 255, 255 })) return false;
    return true;
}

pub fn isUnspecified(self: Addr) bool {
    return switch (self.kind) {
        .invalid => false,
        .v4 => mem.eql(u8, self.bytes[12..16], &[_]u8{ 0, 0, 0, 0 }),
        .v6 => mem.eql(u8, &self.bytes, &([_]u8{0} ** 16)),
    };
}

pub fn next(self: Addr) ?Addr {
    if (!self.isValid()) return null;

    var out = self;
    return switch (self.kind) {
        .invalid => null,
        .v4 => blk: {
            if (incrementBytes(out.bytes[12..16])) break :blk out;
            break :blk null;
        },
        .v6 => blk: {
            if (incrementBytes(&out.bytes)) break :blk out;
            break :blk null;
        },
    };
}

pub fn prev(self: Addr) ?Addr {
    if (!self.isValid()) return null;

    var out = self;
    return switch (self.kind) {
        .invalid => null,
        .v4 => blk: {
            if (decrementBytes(out.bytes[12..16])) break :blk out;
            break :blk null;
        },
        .v6 => blk: {
            if (decrementBytes(&out.bytes)) break :blk out;
            break :blk null;
        },
    };
}

pub fn formatBuf(self: Addr, buf: []u8) error{BufferTooSmall}!usize {
    const need = self.formatLen();
    if (buf.len < need) return error.BufferTooSmall;

    return switch (self.kind) {
        .invalid => blk: {
            @memcpy(buf[0..need], "invalid IP");
            break :blk need;
        },
        .v4 => blk: {
            const written = fmt.bufPrint(buf[0..need], "{d}.{d}.{d}.{d}", .{
                self.bytes[12], self.bytes[13], self.bytes[14], self.bytes[15],
            }) catch unreachable;
            break :blk written.len;
        },
        .v6 => if (self.is4In6())
            formatMappedIpv4(self, buf[0..need])
        else
            formatIpv6(self.bytes, self.zone[0..self.zone_len], buf[0..need]),
    };
}

pub fn formatAllocator(self: Addr, allocator: mem.Allocator) ![]u8 {
    const out = try allocator.alloc(u8, self.formatLen());
    errdefer allocator.free(out);

    const written = try self.formatBuf(out);
    debug.assert(written == out.len);
    return out;
}

fn parseIpv4(s: []const u8) ParseError!Addr {
    var octets: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var cur: u16 = 0;
    var digits: u8 = 0;
    var leading_zero = false;

    for (s) |c| {
        if (c == '.') {
            if (digits == 0) return error.InvalidCharacter;
            if (leading_zero and digits > 1) return error.NonCanonical;
            if (octet_idx == 3) return error.InvalidEnd;
            octets[octet_idx] = @intCast(cur);
            octet_idx += 1;
            cur = 0;
            digits = 0;
            leading_zero = false;
        } else if (c >= '0' and c <= '9') {
            if (digits == 0) leading_zero = c == '0';
            cur = mulAddU16(cur, 10, c - '0') catch return error.Overflow;
            if (cur > 255) return error.Overflow;
            digits += 1;
        } else {
            return error.InvalidCharacter;
        }
    }

    if (digits == 0) return error.Incomplete;
    if (leading_zero and digits > 1) return error.NonCanonical;
    if (octet_idx != 3) return error.Incomplete;
    octets[3] = @intCast(cur);
    return from4(octets);
}

fn parseIpv6(s: []const u8) ParseError!Addr {
    var out = from16([_]u8{0} ** 16);
    var bytes: [16]u8 = undefined;
    var ip_slice: *[16]u8 = &bytes;
    var tail: [16]u8 = undefined;
    @memset(&bytes, 0);

    var x: u16 = 0;
    var saw_any_digits = false;
    var index: u8 = 0;
    var abbrv = false;

    for (s, 0..) |c, i| {
        if (c == ':') {
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
        } else if (c == '.') {
            if (!abbrv or ip_slice[0] != 0xff or ip_slice[1] != 0xff) return error.InvalidIpv4Mapping;
            const start = (mem.lastIndexOfScalar(u8, s[0..i], ':') orelse return error.InvalidCharacter) + 1;
            const v4 = try parseIpv4(s[start..]);
            const v4_bytes = v4.bytes[12..16].*;
            ip_slice = &bytes;
            ip_slice[10] = 0xff;
            ip_slice[11] = 0xff;
            ip_slice[12] = v4_bytes[0];
            ip_slice[13] = v4_bytes[1];
            ip_slice[14] = v4_bytes[2];
            ip_slice[15] = v4_bytes[3];
            out.bytes = bytes;
            return out;
        } else {
            const digit = hexDigit(c) orelse return error.InvalidCharacter;
            x = mulAddU16(x, 16, digit) catch return error.Overflow;
            saw_any_digits = true;
        }
    }

    if (!saw_any_digits and !abbrv) return error.Incomplete;
    if (!abbrv and index < 14) return error.Incomplete;

    if (index == 14) {
        ip_slice[14] = @truncate(x >> 8);
        ip_slice[15] = @truncate(x);
        out.bytes = bytes;
        return out;
    }

    ip_slice[index] = @truncate(x >> 8);
    ip_slice[index + 1] = @truncate(x);
    index += 2;
    @memcpy(bytes[16 - index ..][0..index], ip_slice[0..index]);
    out.bytes = bytes;
    return out;
}

fn compareZones(a: []const u8, b: []const u8) math.Order {
    if (a.len == 0 and b.len == 0) return .eq;
    if (a.len == 0) return .lt;
    if (b.len == 0) return .gt;
    return mem.order(u8, a, b);
}

fn incrementBytes(bytes: []u8) bool {
    var i = bytes.len;
    while (i > 0) {
        i -= 1;
        if (bytes[i] != 0xff) {
            bytes[i] += 1;
            @memset(bytes[i + 1 ..], 0);
            return true;
        }
    }
    return false;
}

fn decrementBytes(bytes: []u8) bool {
    var i = bytes.len;
    while (i > 0) {
        i -= 1;
        if (bytes[i] != 0) {
            bytes[i] -= 1;
            @memset(bytes[i + 1 ..], 0xff);
            return true;
        }
    }
    return false;
}

fn formatLen(self: Addr) usize {
    return switch (self.kind) {
        .invalid => "invalid IP".len,
        .v4 => ipv4Len(self.bytes[12..16]),
        .v6 => if (self.is4In6())
            "::ffff:".len + ipv4Len(self.bytes[12..16]) + zoneSuffixLen(self.zone_len)
        else
            ipv6Len(self.bytes, self.zone[0..self.zone_len]),
    };
}

fn ipv4Len(bytes: []const u8) usize {
    return decimalByteLen(bytes[0]) +
        decimalByteLen(bytes[1]) +
        decimalByteLen(bytes[2]) +
        decimalByteLen(bytes[3]) +
        3;
}

fn ipv6Len(bytes: [16]u8, zone: []const u8) usize {
    const groups = [8]u16{
        (@as(u16, bytes[0]) << 8) | bytes[1],
        (@as(u16, bytes[2]) << 8) | bytes[3],
        (@as(u16, bytes[4]) << 8) | bytes[5],
        (@as(u16, bytes[6]) << 8) | bytes[7],
        (@as(u16, bytes[8]) << 8) | bytes[9],
        (@as(u16, bytes[10]) << 8) | bytes[11],
        (@as(u16, bytes[12]) << 8) | bytes[13],
        (@as(u16, bytes[14]) << 8) | bytes[15],
    };
    const zero_run = findBestIpv6ZeroRun(groups);

    var len: usize = 0;
    var last_was_colon = false;
    var i: usize = 0;
    while (i < groups.len) {
        if (zero_run.start) |start| {
            if (i == start) {
                len += 2;
                last_was_colon = true;
                i += zero_run.len;
                if (i >= groups.len) break;
                continue;
            }
        }

        if (len != 0 and !last_was_colon) len += 1;
        len += hex16Len(groups[i]);
        last_was_colon = false;
        i += 1;
    }

    return len + zoneSuffixLen(@intCast(zone.len));
}

fn zoneSuffixLen(zone_len: u8) usize {
    if (zone_len == 0) return 0;
    return zone_len + 1;
}

fn decimalByteLen(value: u8) usize {
    if (value >= 100) return 3;
    if (value >= 10) return 2;
    return 1;
}

fn hex16Len(value: u16) usize {
    if (value >= 0x1000) return 4;
    if (value >= 0x100) return 3;
    if (value >= 0x10) return 2;
    return 1;
}

fn findBestIpv6ZeroRun(groups: [8]u16) struct { start: ?usize, len: usize } {
    var best_start: ?usize = null;
    var best_len: usize = 0;
    var run_start: ?usize = null;

    for (groups, 0..) |group, i| {
        if (group == 0) {
            if (run_start == null) run_start = i;
        } else if (run_start) |start| {
            const run_len = i - start;
            if (run_len > best_len and run_len >= 2) {
                best_start = start;
                best_len = run_len;
            }
            run_start = null;
        }
    }
    if (run_start) |start| {
        const run_len = groups.len - start;
        if (run_len > best_len and run_len >= 2) {
            best_start = start;
            best_len = run_len;
        }
    }

    return .{
        .start = best_start,
        .len = best_len,
    };
}

fn formatMappedIpv4(self: Addr, buf: []u8) usize {
    const zone = self.zone[0..self.zone_len];
    var pos: usize = 0;
    const prefix = fmt.bufPrint(buf, "::ffff:{d}.{d}.{d}.{d}", .{
        self.bytes[12], self.bytes[13], self.bytes[14], self.bytes[15],
    }) catch unreachable;
    pos += prefix.len;
    if (zone.len != 0) {
        buf[pos] = '%';
        pos += 1;
        @memcpy(buf[pos..][0..zone.len], zone);
        pos += zone.len;
    }
    return pos;
}

fn formatIpv6(bytes: [16]u8, zone: []const u8, buf: []u8) usize {
    const groups = [8]u16{
        (@as(u16, bytes[0]) << 8) | bytes[1],
        (@as(u16, bytes[2]) << 8) | bytes[3],
        (@as(u16, bytes[4]) << 8) | bytes[5],
        (@as(u16, bytes[6]) << 8) | bytes[7],
        (@as(u16, bytes[8]) << 8) | bytes[9],
        (@as(u16, bytes[10]) << 8) | bytes[11],
        (@as(u16, bytes[12]) << 8) | bytes[13],
        (@as(u16, bytes[14]) << 8) | bytes[15],
    };
    const zero_run = findBestIpv6ZeroRun(groups);

    var pos: usize = 0;
    var i: usize = 0;
    while (i < groups.len) {
        if (zero_run.start) |start| {
            if (i == start) {
                if (pos == 0 or buf[pos - 1] != ':') {
                    buf[pos] = ':';
                    pos += 1;
                }
                buf[pos] = ':';
                pos += 1;
                i += zero_run.len;
                if (i >= groups.len) break;
                continue;
            }
        }

        if (pos != 0 and buf[pos - 1] != ':') {
            buf[pos] = ':';
            pos += 1;
        }

        const group_text = fmt.bufPrint(buf[pos..], "{x}", .{groups[i]}) catch unreachable;
        pos += group_text.len;
        i += 1;
    }

    if (zone.len != 0) {
        buf[pos] = '%';
        pos += 1;
        @memcpy(buf[pos..][0..zone.len], zone);
        pos += zone.len;
    }

    return pos;
}

fn hexDigit(c: u8) ?u16 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn mulAddU16(base: u16, factor: u16, addend: u16) error{Overflow}!u16 {
    const mul = @mulWithOverflow(base, factor);
    if (mul[1] != 0) return error.Overflow;
    const sum = @addWithOverflow(mul[0], addend);
    if (sum[1] != 0) return error.Overflow;
    return sum[0];
}

test "net/unit_tests/netip/addr/parse_format_ipv4" {
    const testing = @import("std").testing;
    const addr = try Addr.parse("192.168.1.10");
    try testing.expect(addr.is4());
    try testing.expectEqual(@as(u8, 32), addr.bitLen());

    var buf: [64]u8 = undefined;
    const n = try addr.formatBuf(&buf);
    try testing.expectEqualStrings("192.168.1.10", buf[0..n]);
}

test "net/unit_tests/netip/addr/parse_format_ipv6_compressed" {
    const testing = @import("std").testing;
    const addr = try Addr.parse("2001:db8::1");
    try testing.expect(addr.is6());
    try testing.expect(!addr.is4In6());

    var buf: [64]u8 = undefined;
    const n = try addr.formatBuf(&buf);
    try testing.expectEqualStrings("2001:db8::1", buf[0..n]);
}

test "net/unit_tests/netip/addr/parse_scoped_ipv6" {
    const testing = @import("std").testing;
    const addr = try Addr.parse("fe80::1%eth0");
    try testing.expect(addr.is6());

    var buf: [80]u8 = undefined;
    const n = try addr.formatBuf(&buf);
    try testing.expectEqualStrings("fe80::1%eth0", buf[0..n]);
}

test "net/unit_tests/netip/addr/reject_zone_on_ipv4" {
    const testing = @import("std").testing;
    try testing.expectError(error.ZoneOnIPv4, Addr.parse("192.0.2.1%eth0"));
}

test "net/unit_tests/netip/addr/from16_keeps_ipv4_mapped_ipv6_until_unmap" {
    const testing = @import("std").testing;
    const addr = Addr.from16(.{
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 1, 2, 3, 4,
    });
    try testing.expect(addr.is6());
    try testing.expect(addr.is4In6());
    try testing.expect(!addr.is4());

    const unmapped = addr.unmap();
    try testing.expect(unmapped.is4());
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &unmapped.as4().?);
}

test "net/unit_tests/netip/addr/compare_orders_invalid_ipv4_ipv6" {
    const testing = @import("std").testing;
    const invalid = Addr{};
    const v4 = Addr.from4(.{ 1, 1, 1, 1 });
    const v6 = try Addr.parse("::1");

    try testing.expect(Addr.less(invalid, v4));
    try testing.expect(Addr.less(v4, v6));
    try testing.expectEqual(math.Order.eq, Addr.compare(v6, v6));
}

test "net/unit_tests/netip/addr/next_prev_ipv4" {
    const testing = @import("std").testing;
    const a = try Addr.parse("10.0.0.1");
    const b = a.next().?;
    const c = b.prev().?;

    try testing.expectEqualSlices(u8, &.{ 10, 0, 0, 2 }, &b.as4().?);
    try testing.expectEqualSlices(u8, &.{ 10, 0, 0, 1 }, &c.as4().?);
    try testing.expect((try Addr.parse("255.255.255.255")).next() == null);
    try testing.expect((try Addr.parse("0.0.0.0")).prev() == null);
}

test "net/unit_tests/netip/addr/classification_helpers" {
    const testing = @import("std").testing;
    try testing.expect((try Addr.parse("127.0.0.1")).isLoopback());
    try testing.expect((try Addr.parse("10.1.2.3")).isPrivate());
    try testing.expect((try Addr.parse("224.0.0.1")).isMulticast());
    try testing.expect((try Addr.parse("169.254.1.2")).isLinkLocalUnicast());
    try testing.expect((try Addr.parse("224.0.0.9")).isLinkLocalMulticast());
    try testing.expect((try Addr.parse("0.0.0.0")).isUnspecified());
    try testing.expect((try Addr.parse("8.8.8.8")).isGlobalUnicast());

    try testing.expect((try Addr.parse("::1")).isLoopback());
    try testing.expect((try Addr.parse("fc00::1")).isPrivate());
    try testing.expect((try Addr.parse("ff02::1")).isMulticast());
    try testing.expect((try Addr.parse("fe80::1")).isLinkLocalUnicast());
    try testing.expect((try Addr.parse("ff02::2")).isLinkLocalMulticast());
    try testing.expect((try Addr.parse("::")).isUnspecified());
    try testing.expect((try Addr.parse("2001:db8::1")).isGlobalUnicast());
}

test "net/unit_tests/netip/addr/as16_maps_ipv4_into_ipv4_mapped_ipv6" {
    const testing = @import("std").testing;
    const addr = Addr.from4(.{ 1, 2, 3, 4 });
    const got = addr.as16().?;
    try testing.expectEqualSlices(u8, &v4_in_v6_prefix, got[0..12]);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, got[12..16]);
}

test "net/unit_tests/netip/addr/formatAllocater" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const formatted = try (try Addr.parse("fe80::1%eth0")).formatAllocator(allocator);
    defer allocator.free(formatted);

    try testing.expectEqualStrings("fe80::1%eth0", formatted);
}

test "net/unit_tests/netip/addr/formatBuf_buffer_too_small" {
    const testing = @import("std").testing;
    var buf: [3]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, (try Addr.parse("1.2.3.4")).formatBuf(&buf));
}
