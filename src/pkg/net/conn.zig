//! Abstract bidirectional byte stream (like Go's net.Conn / io.ReadWriteCloser).
//!
//! Any type satisfying this contract can be used as a transport for TLS,
//! HTTP, or other protocol layers — regardless of whether the underlying
//! transport is a TCP socket, a serial port, a memory pipe, etc.

/// Conn contract error set.
pub const Error = error{
    ReadFailed,
    WriteFailed,
    Closed,
    Timeout,
};

/// Validate that `Impl` satisfies the Conn contract.
///
/// Required methods:
///   - `read(*Impl, []u8) Error!usize`
///   - `write(*Impl, []const u8) Error!usize`
///   - `close(*Impl) void`
pub fn from(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (*Impl, []u8) Error!usize, &Impl.read);
        _ = @as(*const fn (*Impl, []const u8) Error!usize, &Impl.write);
        _ = @as(*const fn (*Impl) void, &Impl.close);
    }
    return Impl;
}

/// Adapt a `runtime.socket`-conforming type into a `net.Conn`.
///
/// Maps `send`/`recv`/`close` → `write`/`read`/`close` with error translation.
/// The resulting type satisfies `from()` and can be used with TLS, HTTP, etc.
pub fn SocketConn(comptime Socket: type) type {
    return struct {
        socket: *Socket,

        const Self = @This();

        pub fn init(socket: *Socket) Self {
            return .{ .socket = socket };
        }

        pub fn read(self: *Self, buf: []u8) Error!usize {
            return self.socket.recv(buf) catch |e| switch (e) {
                error.Timeout => Error.Timeout,
                error.Closed => Error.Closed,
                else => Error.ReadFailed,
            };
        }

        pub fn write(self: *Self, data: []const u8) Error!usize {
            return self.socket.send(data) catch |e| switch (e) {
                error.Timeout => Error.Timeout,
                error.Closed => Error.Closed,
                else => Error.WriteFailed,
            };
        }

        pub fn close(self: *Self) void {
            self.socket.close();
        }

        comptime {
            _ = from(Self);
        }
    };
}

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
    const testing = @import("std").testing;
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
    const runtime = @import("runtime");
    const Socket = runtime.std.Socket;
    const Adapted = SocketConn(Socket);
    _ = from(Adapted);
}

test "SocketConn read/write/close over TCP loopback" {
    const std = @import("std");
    const runtime = @import("runtime");
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
    try std.testing.expectEqual(msg.len, written);

    var buf: [64]u8 = undefined;
    const n = try server_conn.read(&buf);
    try std.testing.expectEqualSlices(u8, msg, buf[0..n]);

    client_conn.close();
}

test "SocketConn maps Closed error" {
    const std = @import("std");
    const runtime = @import("runtime");
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
    try std.testing.expectError(Error.Closed, result);
}

test "SocketConn maps Timeout error" {
    const std = @import("std");
    const runtime = @import("runtime");
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
    try std.testing.expectError(Error.Timeout, result);
}
