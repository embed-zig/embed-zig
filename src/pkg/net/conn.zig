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
