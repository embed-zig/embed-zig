const std = @import("std");
const testing = std.testing;
const module = @import("handshake.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Error = module.Error;
const computeAcceptKey = module.computeAcceptKey;
const buildRequest = module.buildRequest;
const validateResponse = module.validateResponse;
const performHandshake = module.performHandshake;
const writeAll = module.writeAll;
const sha1 = test_exports.sha1;
const base64 = test_exports.base64;
const client_mod = test_exports.client_mod;
const ws_guid = test_exports.ws_guid;
const findHeaderEnd = test_exports.findHeaderEnd;
const findHeaderValue = test_exports.findHeaderValue;
const eql = test_exports.eql;
const eqlIgnoreCase = test_exports.eqlIgnoreCase;
const toLower = test_exports.toLower;
const startsWith = test_exports.startsWith;
const BufWriter = test_exports.BufWriter;
const contains = test_exports.contains;
const endsWith = test_exports.endsWith;

test "buildRequest basic" {
    var buf: [512]u8 = undefined;
    const req = try buildRequest(&buf, "echo.websocket.org", "/", "dGhlIHNhbXBsZSBub25jZQ==", null);

    try std.testing.expect(contains(req, "GET / HTTP/1.1\r\n"));
    try std.testing.expect(contains(req, "Host: echo.websocket.org\r\n"));
    try std.testing.expect(contains(req, "Upgrade: websocket\r\n"));
    try std.testing.expect(contains(req, "Connection: Upgrade\r\n"));
    try std.testing.expect(contains(req, "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"));
    try std.testing.expect(contains(req, "Sec-WebSocket-Version: 13\r\n"));
    try std.testing.expect(endsWith(req, "\r\n\r\n"));
}

test "validateResponse 101" {
    var expected_accept: [28]u8 = undefined;
    computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &expected_accept);

    var response_buf: [256]u8 = undefined;
    var writer = BufWriter{ .buf = &response_buf };
    try writer.writeSlice("HTTP/1.1 101 Switching Protocols\r\n");
    try writer.writeSlice("Upgrade: websocket\r\n");
    try writer.writeSlice("Connection: Upgrade\r\n");
    try writer.writeSlice("Sec-WebSocket-Accept: ");
    try writer.writeSlice(&expected_accept);
    try writer.writeSlice("\r\n\r\n");

    const consumed = try validateResponse(response_buf[0..writer.pos], &expected_accept);
    try std.testing.expectEqual(writer.pos, consumed);
}

test "validateResponse non-101 error" {
    const resp = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
    try std.testing.expectError(error.HandshakeFailed, validateResponse(resp, "dummy_accept_value_1234567"));
}

test "buildRequest extra headers" {
    var buf: [1024]u8 = undefined;
    const headers = [_][2][]const u8{
        .{ "X-Api-App-Key", "test-key" },
        .{ "X-Custom", "value" },
    };
    const req = try buildRequest(&buf, "api.example.com", "/ws", "dGhlIHNhbXBsZSBub25jZQ==", &headers);

    try std.testing.expect(contains(req, "X-Api-App-Key: test-key\r\n"));
    try std.testing.expect(contains(req, "X-Custom: value\r\n"));
    try std.testing.expect(contains(req, "GET /ws HTTP/1.1\r\n"));
}

test "computeAcceptKey RFC 6455 example" {
    var accept: [28]u8 = undefined;
    computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &accept);
    try std.testing.expectEqualSlices(u8, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}
