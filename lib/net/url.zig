//! url — zero-allocation URL parser (RFC 3986).
//!
//! Pure string slicing, no platform dependency, no comptime lib needed.
//! Works at both runtime and comptime.
//!
//! Usage:
//!   const u = try url.parse("https://user:pass@example.com:8080/path?q=1#frag");
//!   // u.scheme == "https", u.host == "example.com", u.port == "8080", ...
//!
//!   // Comptime:
//!   const endpoint = comptime url.parse("https://api.example.com:443/v1") catch unreachable;

pub const Url = struct {
    raw: []const u8,
    scheme: []const u8,
    username: []const u8,
    password: []const u8,
    host: []const u8,
    port: []const u8,
    path: []const u8,
    raw_query: []const u8,
    fragment: []const u8,

    pub fn portAsNumber(self: Url) ?u16 {
        if (self.port.len == 0) return null;
        var result: u16 = 0;
        for (self.port) |c| {
            if (c < '0' or c > '9') return null;
            const mul = @as(u32, result) * 10 + (c - '0');
            if (mul > 65535) return null;
            result = @intCast(mul);
        }
        return result;
    }
};

pub const ParseError = error{
    EmptyInput,
    MissingScheme,
    InvalidPort,
};

pub fn parse(input: []const u8) ParseError!Url {
    if (input.len == 0) return error.EmptyInput;

    var result = Url{
        .raw = input,
        .scheme = "",
        .username = "",
        .password = "",
        .host = "",
        .port = "",
        .path = "",
        .raw_query = "",
        .fragment = "",
    };

    var rest = input;

    // 1. scheme
    const scheme_end = indexOf(rest, "://") orelse return error.MissingScheme;
    result.scheme = rest[0..scheme_end];
    rest = rest[scheme_end + 3 ..];

    // 2. Split authority from path/query/fragment
    //    Authority ends at first '/', '?', or '#'
    const authority_end = indexOfAny(rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    rest = rest[authority_end..];

    // 3. Parse authority: [userinfo@]host[:port]
    var host_port: []const u8 = authority;

    if (lastIndexOfScalar(authority, '@')) |at| {
        const userinfo = authority[0..at];
        host_port = authority[at + 1 ..];

        if (indexOfScalar(userinfo, ':')) |colon| {
            result.username = userinfo[0..colon];
            result.password = userinfo[colon + 1 ..];
        } else {
            result.username = userinfo;
        }
    }

    // 4. Parse host[:port], handling IPv6 brackets
    if (host_port.len > 0 and host_port[0] == '[') {
        // IPv6: [addr]:port or [addr]
        if (indexOfScalar(host_port, ']')) |bracket_end| {
            result.host = host_port[1..bracket_end];
            const after_bracket = host_port[bracket_end + 1 ..];
            if (after_bracket.len > 0 and after_bracket[0] == ':') {
                result.port = after_bracket[1..];
                if (!validPort(result.port)) return error.InvalidPort;
            }
        } else {
            result.host = host_port;
        }
    } else {
        if (lastIndexOfScalar(host_port, ':')) |colon| {
            const maybe_port = host_port[colon + 1 ..];
            if (validPort(maybe_port)) {
                result.host = host_port[0..colon];
                result.port = maybe_port;
            } else {
                result.host = host_port;
            }
        } else {
            result.host = host_port;
        }
    }

    // 5. Fragment: split on '#'
    if (indexOfScalar(rest, '#')) |hash| {
        result.fragment = rest[hash + 1 ..];
        rest = rest[0..hash];
    }

    // 6. Query: split on '?'
    if (indexOfScalar(rest, '?')) |q| {
        result.raw_query = rest[q + 1 ..];
        rest = rest[0..q];
    }

    // 7. Path: whatever remains
    result.path = rest;

    return result;
}

fn validPort(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eql(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

fn indexOfScalar(haystack: []const u8, needle: u8) ?usize {
    for (haystack, 0..) |c, i| {
        if (c == needle) return i;
    }
    return null;
}

fn lastIndexOfScalar(haystack: []const u8, needle: u8) ?usize {
    var i: usize = haystack.len;
    while (i > 0) {
        i -= 1;
        if (haystack[i] == needle) return i;
    }
    return null;
}

fn indexOfAny(haystack: []const u8, chars: []const u8) ?usize {
    for (haystack, 0..) |c, i| {
        for (chars) |ch| {
            if (c == ch) return i;
        }
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

test "parse full" {
    const std = @import("std");
    const expectStr = std.testing.expectEqualStrings;

    const u = try parse("https://user:pass@example.com:8080/path?q=1#frag");
    try expectStr("https", u.scheme);
    try expectStr("user", u.username);
    try expectStr("pass", u.password);
    try expectStr("example.com", u.host);
    try expectStr("8080", u.port);
    try expectStr("/path", u.path);
    try expectStr("q=1", u.raw_query);
    try expectStr("frag", u.fragment);
    try std.testing.expectEqual(@as(u16, 8080), u.portAsNumber().?);
}

test "parse minimal" {
    const std = @import("std");
    const expectStr = std.testing.expectEqualStrings;

    const u = try parse("http://example.com");
    try expectStr("http", u.scheme);
    try expectStr("example.com", u.host);
    try expectStr("", u.port);
    try expectStr("", u.path);
    try expectStr("", u.raw_query);
    try expectStr("", u.fragment);
    try std.testing.expectEqual(@as(?u16, null), u.portAsNumber());
}

test "parse ipv6" {
    const std = @import("std");
    const expectStr = std.testing.expectEqualStrings;

    const u = try parse("http://[::1]:8080/path");
    try expectStr("http", u.scheme);
    try expectStr("::1", u.host);
    try expectStr("8080", u.port);
    try expectStr("/path", u.path);
}

test "parse no port" {
    const std = @import("std");
    const expectStr = std.testing.expectEqualStrings;

    const u = try parse("https://example.com/path");
    try expectStr("https", u.scheme);
    try expectStr("example.com", u.host);
    try expectStr("", u.port);
    try expectStr("/path", u.path);
}

test "parse query only" {
    const std = @import("std");
    const expectStr = std.testing.expectEqualStrings;

    const u = try parse("https://example.com?q=1");
    try expectStr("example.com", u.host);
    try expectStr("", u.path);
    try expectStr("q=1", u.raw_query);
    try expectStr("", u.fragment);
}

test "parse fragment only" {
    const std = @import("std");
    const expectStr = std.testing.expectEqualStrings;

    const u = try parse("https://example.com#frag");
    try expectStr("example.com", u.host);
    try expectStr("", u.path);
    try expectStr("", u.raw_query);
    try expectStr("frag", u.fragment);
}

test "parse userinfo no password" {
    const std = @import("std");
    const expectStr = std.testing.expectEqualStrings;

    const u = try parse("https://user@example.com");
    try expectStr("user", u.username);
    try expectStr("", u.password);
    try expectStr("example.com", u.host);
}

test "parse empty path with query" {
    const std = @import("std");
    const expectStr = std.testing.expectEqualStrings;

    const u = try parse("https://example.com?key=val");
    try expectStr("example.com", u.host);
    try expectStr("", u.path);
    try expectStr("key=val", u.raw_query);
}

test "parse comptime" {
    const std = @import("std");
    const expectStr = std.testing.expectEqualStrings;

    const u = comptime parse("https://api.example.com:443/v1/users?limit=10#top") catch unreachable;
    try expectStr("https", u.scheme);
    try expectStr("api.example.com", u.host);
    try expectStr("443", u.port);
    try expectStr("/v1/users", u.path);
    try expectStr("limit=10", u.raw_query);
    try expectStr("top", u.fragment);

    comptime {
        if (u.portAsNumber().? != 443) unreachable;
    }
}

test "parse errors" {
    const std = @import("std");

    try std.testing.expectError(error.EmptyInput, parse(""));
    try std.testing.expectError(error.MissingScheme, parse("example.com"));
    try std.testing.expectError(error.MissingScheme, parse("/path/only"));
}

test "portAsNumber overflow" {
    const std = @import("std");

    const overflow = try parse("http://example.com:99999");
    try std.testing.expectEqual(@as(?u16, null), overflow.portAsNumber());

    const max_port = try parse("http://example.com:65535");
    try std.testing.expectEqual(@as(u16, 65535), max_port.portAsNumber().?);

    const over_max = try parse("http://example.com:65536");
    try std.testing.expectEqual(@as(?u16, null), over_max.portAsNumber());
}
