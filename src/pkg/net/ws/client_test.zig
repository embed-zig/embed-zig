const std = @import("std");
const testing = std.testing;
const module = @import("client.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Message = module.Message;
const MessageType = module.MessageType;
const Client = module.Client;
const copyForward = module.copyForward;
const Allocator = test_exports.Allocator;
const frame = test_exports.frame;
const handshake_mod = test_exports.handshake_mod;
const writeAll = test_exports.writeAll;
const conn_mod = test_exports.conn_mod;
const MockConn = test_exports.MockConn;
const deterministicRng = test_exports.deterministicRng;
const buildServerFrame = test_exports.buildServerFrame;

test "MockConn send + recv roundtrip" {
    const allocator = std.testing.allocator;

    const server_frame = try buildServerFrame(allocator, .text, "hello");
    defer allocator.free(server_frame);

    var mock = MockConn{ .recv_data = server_frame };
    var client = try Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    try client.sendText("hello");

    const msg = (try client.recv()) orelse return error.InvalidResponse;
    try std.testing.expectEqual(MessageType.text, msg.type);
    try std.testing.expectEqualSlices(u8, "hello", msg.payload);
}

test "sendBinary + recv binary" {
    const allocator = std.testing.allocator;
    const binary_data = [_]u8{ 0x00, 0x01, 0x02, 0xFF, 0xFE };

    const server_frame = try buildServerFrame(allocator, .binary, &binary_data);
    defer allocator.free(server_frame);

    var mock = MockConn{ .recv_data = server_frame };
    var client = try Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    try client.sendBinary(&binary_data);

    const msg = (try client.recv()) orelse return error.InvalidResponse;
    try std.testing.expectEqual(MessageType.binary, msg.type);
    try std.testing.expectEqualSlices(u8, &binary_data, msg.payload);
}

test "auto pong on ping" {
    const allocator = std.testing.allocator;

    const ping_frame = try buildServerFrame(allocator, .ping, "");
    defer allocator.free(ping_frame);

    const text_frame = try buildServerFrame(allocator, .text, "after_ping");
    defer allocator.free(text_frame);

    const combined = try allocator.alloc(u8, ping_frame.len + text_frame.len);
    defer allocator.free(combined);
    @memcpy(combined[0..ping_frame.len], ping_frame);
    @memcpy(combined[ping_frame.len..], text_frame);

    var mock = MockConn{ .recv_data = combined };
    var client = try Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    const ping_msg = (try client.recv()) orelse return error.InvalidResponse;
    try std.testing.expectEqual(MessageType.ping, ping_msg.type);

    const sent = mock.sent_buf[0..mock.sent_len];
    try std.testing.expect(sent.len > 0);
    try std.testing.expectEqual(@as(u8, 0x8A), sent[0]);

    const text_msg = (try client.recv()) orelse return error.InvalidResponse;
    try std.testing.expectEqual(MessageType.text, text_msg.type);
    try std.testing.expectEqualSlices(u8, "after_ping", text_msg.payload);
}

test "recv close returns null" {
    const allocator = std.testing.allocator;

    const close_payload = [2]u8{ 0x03, 0xE8 };
    const close_frame = try buildServerFrame(allocator, .close, &close_payload);
    defer allocator.free(close_frame);

    var mock = MockConn{ .recv_data = close_frame };
    var client = try Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    const result = try client.recv();
    try std.testing.expectEqual(@as(?Message, null), result);
}

test "sendClose sends correct close frame" {
    const allocator = std.testing.allocator;

    var mock = MockConn{ .recv_data = "" };
    var client = try Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    try client.sendClose(1000);

    const sent = mock.sent_buf[0..mock.sent_len];
    try std.testing.expect(sent.len >= 2);

    try std.testing.expectEqual(@as(u8, 0x88), sent[0]);
    try std.testing.expectEqual(@as(u8, 0x82), sent[1]);

    const mask_key = sent[2..6].*;
    var status_bytes = [2]u8{ sent[6], sent[7] };
    frame.applyMask(&status_bytes, mask_key);

    const status = @as(u16, status_bytes[0]) << 8 | @as(u16, status_bytes[1]);
    try std.testing.expectEqual(@as(u16, 1000), status);
}

test "recv on closed client returns null" {
    const allocator = std.testing.allocator;

    var mock = MockConn{ .recv_data = "" };
    var client = try Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    client.close();
    const result = try client.recv();
    try std.testing.expectEqual(@as(?Message, null), result);
}

test "sendText on closed client returns error" {
    const allocator = std.testing.allocator;

    var mock = MockConn{ .recv_data = "" };
    var client = try Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    client.state = .closed;
    try std.testing.expectError(error.Closed, client.sendText("hello"));
}
