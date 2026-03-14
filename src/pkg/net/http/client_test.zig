const std = @import("std");
const testing = std.testing;
const module = @import("client.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Client = module.Client;
const transport_mod = test_exports.transport_mod;
const RoundTripRequest = test_exports.RoundTripRequest;
const RoundTripResponse = test_exports.RoundTripResponse;
const TransportError = test_exports.TransportError;
const Scheme = test_exports.Scheme;
const Method = test_exports.Method;
const MockTransport = test_exports.MockTransport;
const initMockClient = test_exports.initMockClient;

test "Client.get dispatches to transport" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    const resp = try c.get("http://example.com/api", &buf);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expectEqual(Method.GET, mock.last_method.?);
    try std.testing.expectEqualStrings("example.com", mock.last_host.?);
    try std.testing.expectEqualStrings("/api", mock.last_path.?);
}

test "Client.post dispatches to transport" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    _ = try c.post("http://example.com/submit", "data", &buf);
    try std.testing.expectEqual(Method.POST, mock.last_method.?);
}

test "Client.postJson dispatches to transport" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    _ = try c.postJson("http://example.com/api", "{}", &buf);
    try std.testing.expectEqual(Method.POST, mock.last_method.?);
}

test "Client.put dispatches to transport" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    _ = try c.put("http://example.com/resource", "data", &buf);
    try std.testing.expectEqual(Method.PUT, mock.last_method.?);
}

test "Client.delete dispatches to transport" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    _ = try c.delete("http://example.com/resource", &buf);
    try std.testing.expectEqual(Method.DELETE, mock.last_method.?);
}

test "Client detects HTTPS scheme" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    _ = try c.get("https://secure.example.com/api", &buf);
    try std.testing.expectEqual(Scheme.https, mock.last_scheme.?);
    try std.testing.expectEqualStrings("secure.example.com", mock.last_host.?);
}

test "Client invalid URL returns error" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    try std.testing.expectError(error.InvalidUrl, c.get("not a url at all", &buf));
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
}

test "Client multiple sequential requests" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    _ = try c.get("http://a.com/1", &buf);
    _ = try c.get("http://b.com/2", &buf);
    _ = try c.post("http://c.com/3", null, &buf);
    try std.testing.expectEqual(@as(usize, 3), mock.call_count);
}

test "Client response body access" {
    var mock = MockTransport{
        .response_text = "HTTP/1.1 201 Created\r\nContent-Length: 11\r\n\r\n{\"id\": 123}",
    };
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    const resp = try c.post("http://api.example.com/create", "{}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status_code);
    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqualStrings("{\"id\": 123}", resp.body());
}
