const std = @import("std");
const testing = std.testing;
const module = @import("conn.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Error = module.Error;
const from = module.from;
const SocketConn = module.SocketConn;
const runtime = test_exports.runtime;

test "Conn contract validation with valid type" {
    const ValidConn = struct {
        const Self = @This();
        pub fn read(_: *Self, _: []u8) Error!usize {
            return 0;
        }
        pub fn write(_: *Self, _: []const u8) Error!usize {
            return 0;
        }
        pub fn close(_: *Self) void {}
    };
    _ = from(ValidConn);
}

test "Conn Error values are distinct" {
    try testing.expect(@intFromError(Error.ReadFailed) != @intFromError(Error.WriteFailed));
    try testing.expect(@intFromError(Error.ReadFailed) != @intFromError(Error.Closed));
    try testing.expect(@intFromError(Error.ReadFailed) != @intFromError(Error.Timeout));
    try testing.expect(@intFromError(Error.WriteFailed) != @intFromError(Error.Closed));
    try testing.expect(@intFromError(Error.WriteFailed) != @intFromError(Error.Timeout));
    try testing.expect(@intFromError(Error.Closed) != @intFromError(Error.Timeout));
}

test "Conn from returns the same type" {
    const MyConn = struct {
        const Self = @This();
        pub fn read(_: *Self, _: []u8) Error!usize {
            return 0;
        }
        pub fn write(_: *Self, _: []const u8) Error!usize {
            return 0;
        }
        pub fn close(_: *Self) void {}
    };
    const Validated = from(MyConn);
    try @import("std").testing.expect(Validated == MyConn);
}

test "SocketConn satisfies Conn contract" {
    const Socket = runtime.std.Socket;
    const Adapted = SocketConn(Socket);
    _ = from(Adapted);
}

test "SocketConn read/write/close over TCP loopback" {
    const Socket = runtime.std.Socket;

    var listener = try Socket.tcp();
    defer listener.close();
    try listener.bind(.{ 127, 0, 0, 1 }, 0);
    try listener.listen();
    const port = try listener.getBoundPort();

    var client_sock = try Socket.tcp();
    try client_sock.connect(.{ 127, 0, 0, 1 }, port);

    var server_sock = try listener.accept();
    defer server_sock.close();

    var client_conn = SocketConn(Socket).init(&client_sock);
    var server_conn = SocketConn(Socket).init(&server_sock);

    const msg = "hello via SocketConn";
    const written = try client_conn.write(msg);
    try testing.expectEqual(msg.len, written);

    var buf: [64]u8 = undefined;
    const n = try server_conn.read(&buf);
    try testing.expectEqualSlices(u8, msg, buf[0..n]);

    client_conn.close();
}

test "SocketConn maps Closed error" {
    const Socket = runtime.std.Socket;

    var listener = try Socket.tcp();
    defer listener.close();
    try listener.bind(.{ 127, 0, 0, 1 }, 0);
    try listener.listen();
    const port = try listener.getBoundPort();

    var client_sock = try Socket.tcp();
    try client_sock.connect(.{ 127, 0, 0, 1 }, port);

    var server_sock = try listener.accept();
    server_sock.close();

    var client_conn = SocketConn(Socket).init(&client_sock);
    defer client_conn.close();

    var buf: [64]u8 = undefined;
    const result = client_conn.read(&buf);
    try testing.expectError(Error.Closed, result);
}

test "SocketConn maps Timeout error" {
    const Socket = runtime.std.Socket;

    var listener = try Socket.tcp();
    defer listener.close();
    try listener.bind(.{ 127, 0, 0, 1 }, 0);
    try listener.listen();
    const port = try listener.getBoundPort();

    var client_sock = try Socket.tcp();
    try client_sock.connect(.{ 127, 0, 0, 1 }, port);
    defer client_sock.close();

    var server_sock = try listener.accept();
    defer server_sock.close();

    client_sock.setRecvTimeout(50);
    var client_conn = SocketConn(Socket).init(&client_sock);

    var buf: [64]u8 = undefined;
    const result = client_conn.read(&buf);
    try testing.expectError(Error.Timeout, result);
}
