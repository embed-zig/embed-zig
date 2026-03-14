const std = @import("std");
const testing = std.testing;
const module = @import("url.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const ParseError = module.ParseError;
const Url = module.Url;
const QueryIterator = module.QueryIterator;
const parse = module.parse;
const getSchemeEnd = test_exports.getSchemeEnd;
const parseAuthority = test_exports.parseAuthority;
const parsePort = test_exports.parsePort;
const isAlpha = test_exports.isAlpha;
const isDigit = test_exports.isDigit;
const indexOf = test_exports.indexOf;
const lastIndexOf = test_exports.lastIndexOf;

test "full URL with all components" {
    const u = try parse("mqtts://user:pass@example.com:8883/topic?qos=1#ref");
    try testing.expectEqualStrings("mqtts", u.scheme.?);
    try testing.expectEqualStrings("user", u.username.?);
    try testing.expectEqualStrings("pass", u.password.?);
    try testing.expectEqualStrings("example.com", u.host.?);
    try testing.expectEqual(@as(u16, 8883), u.port.?);
    try testing.expectEqualStrings("/topic", u.path);
    try testing.expectEqualStrings("qos=1", u.raw_query.?);
    try testing.expectEqualStrings("ref", u.fragment.?);
}

test "HTTP URL without userinfo" {
    const u = try parse("https://www.example.com:443/path/to/resource?key=value");
    try testing.expectEqualStrings("https", u.scheme.?);
    try testing.expect(u.username == null);
    try testing.expect(u.password == null);
    try testing.expectEqualStrings("www.example.com", u.host.?);
    try testing.expectEqual(@as(u16, 443), u.port.?);
    try testing.expectEqualStrings("/path/to/resource", u.path);
    try testing.expectEqualStrings("key=value", u.raw_query.?);
    try testing.expect(u.fragment == null);
}

test "URL without port" {
    const u = try parse("http://example.com/path");
    try testing.expectEqualStrings("http", u.scheme.?);
    try testing.expectEqualStrings("example.com", u.host.?);
    try testing.expect(u.port == null);
    try testing.expectEqualStrings("/path", u.path);
    try testing.expectEqual(@as(u16, 80), u.portOrDefault(80));
}

test "URL without path" {
    const u = try parse("http://example.com");
    try testing.expectEqualStrings("http", u.scheme.?);
    try testing.expectEqualStrings("example.com", u.host.?);
    try testing.expectEqualStrings("", u.path);
}

test "URL with only scheme and host" {
    const u = try parse("mqtt://broker.local");
    try testing.expectEqualStrings("mqtt", u.scheme.?);
    try testing.expectEqualStrings("broker.local", u.host.?);
    try testing.expect(u.port == null);
    try testing.expectEqualStrings("", u.path);
}

test "username without password" {
    const u = try parse("ftp://admin@files.example.com/pub");
    try testing.expectEqualStrings("ftp", u.scheme.?);
    try testing.expectEqualStrings("admin", u.username.?);
    try testing.expect(u.password == null);
    try testing.expectEqualStrings("files.example.com", u.host.?);
    try testing.expectEqualStrings("/pub", u.path);
}

test "empty password" {
    const u = try parse("ftp://admin:@files.example.com/pub");
    try testing.expectEqualStrings("admin", u.username.?);
    try testing.expectEqualStrings("", u.password.?);
}

test "IPv6 host without port" {
    const u = try parse("http://[::1]/path");
    try testing.expectEqualStrings("[::1]", u.host.?);
    try testing.expectEqualStrings("::1", u.hostname().?);
    try testing.expect(u.port == null);
    try testing.expectEqualStrings("/path", u.path);
}

test "IPv6 host with port" {
    const u = try parse("http://[2001:db8::1]:8080/path");
    try testing.expectEqualStrings("[2001:db8::1]", u.host.?);
    try testing.expectEqualStrings("2001:db8::1", u.hostname().?);
    try testing.expectEqual(@as(u16, 8080), u.port.?);
    try testing.expectEqualStrings("/path", u.path);
}

test "IPv6 trailing colon, no port" {
    const u = try parse("http://[::1]:/path");
    try testing.expectEqualStrings("[::1]", u.host.?);
    try testing.expect(u.port == null);
    try testing.expectEqualStrings("/path", u.path);
}

test "IPv6 unclosed bracket" {
    try testing.expectError(error.InvalidHost, parse("http://[::1/path"));
}

test "IPv6 junk after bracket" {
    try testing.expectError(error.InvalidHost, parse("http://[::1]x/path"));
}

test "file URI with empty authority" {
    const u = try parse("file:///etc/hosts");
    try testing.expectEqualStrings("file", u.scheme.?);
    try testing.expect(u.host == null);
    try testing.expectEqualStrings("/etc/hosts", u.path);
}

test "relative reference (no scheme)" {
    const u = try parse("/path/to/resource?q=1#frag");
    try testing.expect(u.scheme == null);
    try testing.expect(u.host == null);
    try testing.expectEqualStrings("/path/to/resource", u.path);
    try testing.expectEqualStrings("q=1", u.raw_query.?);
    try testing.expectEqualStrings("frag", u.fragment.?);
}

test "empty string" {
    const u = try parse("");
    try testing.expect(u.scheme == null);
    try testing.expect(u.host == null);
    try testing.expectEqualStrings("", u.path);
    try testing.expect(u.raw_query == null);
    try testing.expect(u.fragment == null);
}

test "fragment only" {
    const u = try parse("#section");
    try testing.expect(u.scheme == null);
    try testing.expectEqualStrings("section", u.fragment.?);
    try testing.expectEqualStrings("", u.path);
}

test "query only" {
    const u = try parse("?key=value");
    try testing.expect(u.scheme == null);
    try testing.expectEqualStrings("key=value", u.raw_query.?);
    try testing.expectEqualStrings("", u.path);
}

test "opaque URI (mailto)" {
    const u = try parse("mailto:user@example.com");
    try testing.expectEqualStrings("mailto", u.scheme.?);
    // No authority (no "//"), so "user@example.com" is the path
    try testing.expectEqualStrings("user@example.com", u.path);
    try testing.expect(u.host == null);
}

test "scheme with digits and special chars" {
    const u = try parse("coap+tcp://sensor.local:5683/temp");
    try testing.expectEqualStrings("coap+tcp", u.scheme.?);
    try testing.expectEqualStrings("sensor.local", u.host.?);
    try testing.expectEqual(@as(u16, 5683), u.port.?);
}

test "invalid port: non-numeric" {
    try testing.expectError(error.InvalidPort, parse("http://host:abc/path"));
}

test "invalid port: exceeds u16" {
    try testing.expectError(error.InvalidPort, parse("http://host:99999/path"));
}

test "trailing colon, no port" {
    const u = try parse("http://host:/path");
    try testing.expectEqualStrings("host", u.host.?);
    try testing.expect(u.port == null);
    try testing.expectEqualStrings("/path", u.path);
}

test "port boundary: 0" {
    const u = try parse("http://host:0/path");
    try testing.expectEqual(@as(u16, 0), u.port.?);
}

test "port boundary: 65535" {
    const u = try parse("http://host:65535/path");
    try testing.expectEqual(@as(u16, 65535), u.port.?);
}

test "port boundary: 65536 overflows" {
    try testing.expectError(error.InvalidPort, parse("http://host:65536/path"));
}

test "query with multiple params" {
    const u = try parse("http://h/p?a=1&b=2&c=3");
    try testing.expectEqualStrings("a=1&b=2&c=3", u.raw_query.?);
}

test "query iterator" {
    const u = try parse("http://h/p?a=1&b=2&flag&c=");
    var it = u.queryIterator();

    const e1 = it.next().?;
    try testing.expectEqualStrings("a", e1.key);
    try testing.expectEqualStrings("1", e1.value.?);

    const e2 = it.next().?;
    try testing.expectEqualStrings("b", e2.key);
    try testing.expectEqualStrings("2", e2.value.?);

    const e3 = it.next().?;
    try testing.expectEqualStrings("flag", e3.key);
    try testing.expect(e3.value == null);

    const e4 = it.next().?;
    try testing.expectEqualStrings("c", e4.key);
    try testing.expectEqualStrings("", e4.value.?);

    try testing.expect(it.next() == null);
}

test "query iterator: empty segments" {
    const u = try parse("http://h/p?a=1&&b=2");
    var it = u.queryIterator();

    const e1 = it.next().?;
    try testing.expectEqualStrings("a", e1.key);

    const e2 = it.next().?;
    try testing.expectEqualStrings("b", e2.key);

    try testing.expect(it.next() == null);
}

test "query iterator: reset" {
    const u = try parse("http://h/p?x=1");
    var it = u.queryIterator();
    _ = it.next();
    try testing.expect(it.next() == null);

    it.reset();
    const e = it.next().?;
    try testing.expectEqualStrings("x", e.key);
}

test "query iterator: no query" {
    const u = try parse("http://h/p");
    var it = u.queryIterator();
    try testing.expect(it.next() == null);
}

test "hostname: regular host" {
    const u = try parse("http://example.com/");
    try testing.expectEqualStrings("example.com", u.hostname().?);
}

test "hostname: no host" {
    const u = try parse("/path");
    try testing.expect(u.hostname() == null);
}

test "portOrDefault: port present" {
    const u = try parse("http://h:9090/");
    try testing.expectEqual(@as(u16, 9090), u.portOrDefault(80));
}

test "portOrDefault: port absent" {
    const u = try parse("http://h/");
    try testing.expectEqual(@as(u16, 80), u.portOrDefault(80));
}

test "raw field preserves original input" {
    const input = "http://example.com/path?q=1#f";
    const u = try parse(input);
    try testing.expectEqualStrings(input, u.raw);
}

test "query and fragment interaction" {
    // '?' in fragment should not be treated as query delimiter
    const u = try parse("http://h/p?q=1#frag?ment");
    try testing.expectEqualStrings("q=1", u.raw_query.?);
    try testing.expectEqualStrings("frag?ment", u.fragment.?);
}

test "fragment with '#' characters" {
    // Only the first '#' splits; rest is part of fragment
    const u = try parse("http://h/p#a#b#c");
    try testing.expectEqualStrings("a#b#c", u.fragment.?);
}

test "MQTT URL (primary use case)" {
    const u = try parse("mqtt://device:secret@broker.haivivi.com:1883");
    try testing.expectEqualStrings("mqtt", u.scheme.?);
    try testing.expectEqualStrings("device", u.username.?);
    try testing.expectEqualStrings("secret", u.password.?);
    try testing.expectEqualStrings("broker.haivivi.com", u.host.?);
    try testing.expectEqual(@as(u16, 1883), u.port.?);
    try testing.expectEqualStrings("", u.path);
}

test "MQTTS URL" {
    const u = try parse("mqtts://broker.haivivi.com:8883/telemetry");
    try testing.expectEqualStrings("mqtts", u.scheme.?);
    try testing.expectEqualStrings("broker.haivivi.com", u.host.?);
    try testing.expectEqual(@as(u16, 8883), u.port.?);
    try testing.expectEqualStrings("/telemetry", u.path);
}

test "WebSocket URL" {
    const u = try parse("wss://stream.example.com/v1/events?token=abc");
    try testing.expectEqualStrings("wss", u.scheme.?);
    try testing.expectEqualStrings("stream.example.com", u.host.?);
    try testing.expectEqualStrings("/v1/events", u.path);
    try testing.expectEqualStrings("token=abc", u.raw_query.?);
}
