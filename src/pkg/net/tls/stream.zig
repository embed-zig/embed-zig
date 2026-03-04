const std = @import("std");
const conn_mod = @import("../conn.zig");
const client_mod = @import("client.zig");
const common = @import("common.zig");

pub const Options = struct {
    skip_cert_verify: bool = false,
    timeout_ms: u32 = 30000,
};

/// TLS Stream — wraps a plain `Conn` into an encrypted stream that itself
/// satisfies the `net.conn.from` contract (`read`, `write`, `close`).
///
/// This is the primary high-level API: create a `Stream`, call `handshake`,
/// then use `read`/`write`/`close` like any other `Conn`.
pub fn Stream(comptime Conn: type, comptime Crypto: type, comptime Mutex: type) type {
    comptime {
        _ = conn_mod.from(Conn);
    }

    return struct {
        client: ?client_mod.Client(Conn, Crypto, Mutex),
        conn: *Conn,
        allocator: std.mem.Allocator,
        hostname: []const u8,
        options: Options,

        const Self = @This();

        pub fn init(conn: *Conn, allocator: std.mem.Allocator, hostname: []const u8, options: Options) !Self {
            return .{
                .client = null,
                .conn = conn,
                .allocator = allocator,
                .hostname = hostname,
                .options = options,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.client) |*c| {
                c.deinit();
                self.client = null;
            }
        }

        /// Perform TLS handshake, upgrading the underlying Conn.
        pub fn handshake(self: *Self) !void {
            self.client = try client_mod.Client(Conn, Crypto, Mutex).init(self.conn, .{
                .allocator = self.allocator,
                .hostname = self.hostname,
                .skip_verify = self.options.skip_cert_verify,
                .timeout_ms = self.options.timeout_ms,
            });
            errdefer {
                if (self.client) |*c| c.deinit();
                self.client = null;
            }

            try self.client.?.connect();
        }

        /// Satisfies `net.conn.from` — read decrypted data.
        pub fn read(self: *Self, buffer: []u8) conn_mod.Error!usize {
            if (self.client) |*c| {
                return c.recv(buffer) catch return conn_mod.Error.ReadFailed;
            }
            return conn_mod.Error.Closed;
        }

        /// Satisfies `net.conn.from` — write data (encrypted on the wire).
        pub fn write(self: *Self, data: []const u8) conn_mod.Error!usize {
            if (self.client) |*c| {
                return c.send(data) catch return conn_mod.Error.WriteFailed;
            }
            return conn_mod.Error.Closed;
        }

        /// Satisfies `net.conn.from` — send close_notify and close.
        pub fn close(self: *Self) void {
            if (self.client) |*c| {
                c.close() catch {};
            }
        }
    };
}

test "Stream satisfies Conn contract" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    const MockConn = struct {
        const Self = @This();
        pub fn read(_: *Self, _: []u8) conn_mod.Error!usize {
            return 0;
        }
        pub fn write(_: *Self, _: []const u8) conn_mod.Error!usize {
            return 0;
        }
        pub fn close(_: *Self) void {}
    };

    const TlsStream = Stream(MockConn, Crypto, Mutex);
    _ = conn_mod.from(TlsStream);
}

const TestMockConn = struct {
    const Self = @This();
    closed: bool = false,

    pub fn read(_: *Self, _: []u8) conn_mod.Error!usize {
        return conn_mod.Error.ReadFailed;
    }
    pub fn write(_: *Self, _: []const u8) conn_mod.Error!usize {
        return conn_mod.Error.WriteFailed;
    }
    pub fn close(self: *Self) void {
        self.closed = true;
    }
};

test "Stream init and deinit" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    var s = try Stream(TestMockConn, Crypto, Mutex).init(&conn, std.testing.allocator, "example.com", .{});
    defer s.deinit();

    try std.testing.expect(s.client == null);
}

test "Stream read before handshake returns Closed" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    var s = try Stream(TestMockConn, Crypto, Mutex).init(&conn, std.testing.allocator, "example.com", .{});
    defer s.deinit();

    var buf: [64]u8 = undefined;
    try std.testing.expectError(conn_mod.Error.Closed, s.read(&buf));
}

test "Stream write before handshake returns Closed" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    var s = try Stream(TestMockConn, Crypto, Mutex).init(&conn, std.testing.allocator, "example.com", .{});
    defer s.deinit();

    try std.testing.expectError(conn_mod.Error.Closed, s.write("hello"));
}

test "Stream close before handshake is safe" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    var s = try Stream(TestMockConn, Crypto, Mutex).init(&conn, std.testing.allocator, "example.com", .{});
    defer s.deinit();

    s.close();
    try std.testing.expect(s.client == null);
}

test "Stream deinit is idempotent" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    var s = try Stream(TestMockConn, Crypto, Mutex).init(&conn, std.testing.allocator, "example.com", .{});

    s.deinit();
    s.deinit();
}

test "Stream options defaults" {
    const opts: Options = .{};
    try std.testing.expectEqual(false, opts.skip_cert_verify);
    try std.testing.expectEqual(@as(u32, 30000), opts.timeout_ms);
}

test "Stream options custom" {
    const opts: Options = .{
        .skip_cert_verify = true,
        .timeout_ms = 5000,
    };
    try std.testing.expectEqual(true, opts.skip_cert_verify);
    try std.testing.expectEqual(@as(u32, 5000), opts.timeout_ms);
}

test "Stream preserves hostname and allocator" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    var s = try Stream(TestMockConn, Crypto, Mutex).init(&conn, std.testing.allocator, "my.host.com", .{});
    defer s.deinit();

    try std.testing.expectEqualStrings("my.host.com", s.hostname);
}
