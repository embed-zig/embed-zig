const std = @import("std");
const runtime = @import("runtime");
const conn_mod = @import("../conn.zig");
const common = @import("common.zig");
const record = @import("record.zig");
const handshake = @import("handshake.zig");

const ProtocolVersion = common.ProtocolVersion;
const CipherSuite = common.CipherSuite;
const AlertDescription = common.AlertDescription;

pub fn Config(comptime Crypto: type) type {
    const CaStore = if (@hasDecl(Crypto, "x509") and @hasDecl(Crypto.x509, "CaStore"))
        Crypto.x509.CaStore
    else
        void;

    return struct {
        allocator: std.mem.Allocator,
        hostname: []const u8 = "",
        skip_verify: bool = false,
        ca_store: ?CaStore = null,
        alpn_protocols: []const []const u8 = &.{},
        min_version: ProtocolVersion = .tls_1_2,
        max_version: ProtocolVersion = .tls_1_3,
        timeout_ms: u32 = 30000,
    };
}

/// TLS Client — upgrades a plain `Conn` into a secure channel.
///
/// Thread-safe: `send` and `recv` can be called concurrently.
///
/// Type parameters:
///   - `Conn`:   underlying transport (must satisfy `net.conn.from` contract)
///   - `Crypto`: crypto primitives (must satisfy `runtime.crypto` contract, includes `Rng`)
///   - `Mutex`:  mutex type (must satisfy `runtime.sync.Mutex` contract)
pub fn Client(comptime Conn: type, comptime Crypto: type, comptime Mutex: type) type {
    comptime {
        _ = conn_mod.from(Conn);
        _ = runtime.sync.Mutex(Mutex);
    }

    return struct {
        config: Config(Crypto),
        conn: *Conn,
        hs: handshake.ClientHandshake(Conn, Crypto),
        connected: bool,
        received_close_notify: bool,

        write_mutex: Mutex,
        read_mutex: Mutex,

        read_buffer: []u8,
        write_buffer: []u8,

        pending_plaintext: [common.MAX_CIPHERTEXT_LEN]u8 = undefined,
        pending_pos: usize = 0,
        pending_len: usize = 0,

        const Self = @This();

        pub const crypto = Crypto;

        pub fn init(conn: *Conn, config: Config(Crypto)) !Self {
            const read_buffer = try config.allocator.alloc(u8, common.MAX_CIPHERTEXT_LEN + 256);
            errdefer config.allocator.free(read_buffer);

            const write_buffer = try config.allocator.alloc(u8, common.MAX_CIPHERTEXT_LEN + 256);
            errdefer config.allocator.free(write_buffer);

            const Hs = handshake.ClientHandshake(Conn, Crypto);
            const hs_ca_store: if (Hs.CaStoreType != void) ?Hs.CaStoreType else void =
                if (Hs.CaStoreType != void) config.ca_store else {};

            return Self{
                .config = config,
                .conn = conn,
                .hs = Hs.init(
                    conn,
                    config.hostname,
                    config.allocator,
                    hs_ca_store,
                ),
                .connected = false,
                .received_close_notify = false,
                .write_mutex = Mutex.init(),
                .read_mutex = Mutex.init(),
                .read_buffer = read_buffer,
                .write_buffer = write_buffer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.read_mutex.deinit();
            self.write_mutex.deinit();
            self.config.allocator.free(self.read_buffer);
            self.config.allocator.free(self.write_buffer);
        }

        /// Perform TLS handshake over the underlying Conn.
        /// Must be called before any concurrent send/recv.
        pub fn connect(self: *Self) !void {
            try self.hs.handshake(self.write_buffer);
            self.connected = true;
        }

        /// Send encrypted data (thread-safe).
        pub fn send(self: *Self, data: []const u8) !usize {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();

            if (!@atomicLoad(bool, &self.connected, .acquire)) return error.NotConnected;
            if (@atomicLoad(bool, &self.received_close_notify, .acquire)) return error.ConnectionClosed;

            var sent: usize = 0;
            while (sent < data.len) {
                const chunk_size = @min(data.len - sent, common.MAX_PLAINTEXT_LEN);
                _ = try self.hs.records.writeRecord(
                    .application_data,
                    data[sent..][0..chunk_size],
                    self.write_buffer,
                );
                sent += chunk_size;
            }
            return sent;
        }

        /// Receive and decrypt data (thread-safe).
        pub fn recv(self: *Self, buffer: []u8) !usize {
            self.read_mutex.lock();
            defer self.read_mutex.unlock();

            if (!@atomicLoad(bool, &self.connected, .acquire)) return error.NotConnected;
            if (@atomicLoad(bool, &self.received_close_notify, .acquire)) return 0;

            if (self.pending_len > 0) {
                const n = @min(self.pending_len, buffer.len);
                @memcpy(buffer[0..n], self.pending_plaintext[self.pending_pos..][0..n]);
                self.pending_pos += n;
                self.pending_len -= n;
                return n;
            }

            while (true) {
                var plaintext: [common.MAX_CIPHERTEXT_LEN]u8 = undefined;
                const result = try self.hs.records.readRecord(self.read_buffer, &plaintext);

                switch (result.content_type) {
                    .application_data => {
                        const copy_len = @min(result.length, buffer.len);
                        @memcpy(buffer[0..copy_len], plaintext[0..copy_len]);

                        if (result.length > copy_len) {
                            const leftover = result.length - copy_len;
                            @memcpy(self.pending_plaintext[0..leftover], plaintext[copy_len..result.length]);
                            self.pending_pos = 0;
                            self.pending_len = leftover;
                        }

                        return copy_len;
                    },
                    .alert => {
                        if (result.length >= 2) {
                            if (std.meta.intToEnum(AlertDescription, plaintext[1])) |desc| {
                                if (desc == .close_notify) {
                                    @atomicStore(bool, &self.received_close_notify, true, .release);
                                    return 0;
                                }
                            } else |_| {}
                        }
                        return error.AlertReceived;
                    },
                    .handshake => {
                        continue;
                    },
                    else => return error.UnexpectedMessage,
                }
            }
        }

        /// Send close_notify alert and close connection (thread-safe).
        pub fn close(self: *Self) !void {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();

            if (@atomicLoad(bool, &self.connected, .acquire) and !@atomicLoad(bool, &self.received_close_notify, .acquire)) {
                try self.hs.records.sendAlert(
                    .warning,
                    .close_notify,
                    self.write_buffer,
                );
            }
            @atomicStore(bool, &self.connected, false, .release);
        }

        pub fn getVersion(self: *Self) ProtocolVersion {
            return self.hs.version;
        }

        pub fn getCipherSuite(self: *Self) CipherSuite {
            return self.hs.cipher_suite;
        }

        pub fn isConnected(self: *Self) bool {
            return @atomicLoad(bool, &self.connected, .acquire) and
                !@atomicLoad(bool, &self.received_close_notify, .acquire);
        }
    };
}

pub const Error = error{
    NotConnected,
    ConnectionClosed,
    AlertReceived,
    UnexpectedMessage,
    HandshakeFailed,
    OutOfMemory,
    BufferTooSmall,
    InvalidHandshake,
    UnsupportedGroup,
    InvalidPublicKey,
    HelloRetryNotSupported,
    UnsupportedCipherSuite,
    InvalidKeyLength,
    InvalidIvLength,
    RecordTooLarge,
    DecryptionFailed,
    BadRecordMac,
    UnexpectedRecord,
    IdentityElement,
    CertificateVerificationFailed,
};

/// Convenience: create + handshake in one call.
pub fn connect(
    comptime Conn: type,
    comptime Crypto: type,
    comptime Mutex: type,
    conn: *Conn,
    hostname: []const u8,
    allocator: std.mem.Allocator,
) !Client(Conn, Crypto, Mutex) {
    var tls_client = try Client(Conn, Crypto, Mutex).init(conn, .{
        .allocator = allocator,
        .hostname = hostname,
    });
    errdefer tls_client.deinit();

    try tls_client.connect();
    return tls_client;
}

test "Config defaults" {
    const Crypto = @import("runtime").std.Crypto;

    const TestConfig = Config(Crypto);
    const config: TestConfig = .{
        .allocator = std.testing.allocator,
        .hostname = "example.com",
    };

    try std.testing.expectEqual(ProtocolVersion.tls_1_2, config.min_version);
    try std.testing.expectEqual(ProtocolVersion.tls_1_3, config.max_version);
    try std.testing.expectEqual(false, config.skip_verify);
}

const TestMockConn = struct {
    write_buf: [16384]u8 = undefined,
    write_len: usize = 0,
    read_buf: [16384]u8 = undefined,
    read_len: usize = 0,
    read_pos: usize = 0,
    closed: bool = false,

    pub fn read(self: *TestMockConn, buf: []u8) conn_mod.Error!usize {
        if (self.closed) return conn_mod.Error.Closed;
        if (self.read_pos >= self.read_len) return conn_mod.Error.ReadFailed;
        const avail = self.read_len - self.read_pos;
        const n = @min(avail, buf.len);
        @memcpy(buf[0..n], self.read_buf[self.read_pos..][0..n]);
        self.read_pos += n;
        return n;
    }

    pub fn write(self: *TestMockConn, data: []const u8) conn_mod.Error!usize {
        if (self.closed) return conn_mod.Error.Closed;
        const space = self.write_buf.len - self.write_len;
        const n = @min(space, data.len);
        if (n == 0) return conn_mod.Error.WriteFailed;
        @memcpy(self.write_buf[self.write_len..][0..n], data[0..n]);
        self.write_len += n;
        return n;
    }

    pub fn close(self: *TestMockConn) void {
        self.closed = true;
    }

    fn feedData(self: *TestMockConn, data: []const u8) void {
        @memcpy(self.read_buf[0..data.len], data);
        self.read_len = data.len;
        self.read_pos = 0;
    }
};

test "Client init and deinit" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    const TestClient = Client(TestMockConn, Crypto, Mutex);

    var c = try TestClient.init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.example.com",
    });
    defer c.deinit();

    try std.testing.expect(!c.isConnected());
}

test "Client send before connect returns NotConnected" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    try std.testing.expectError(error.NotConnected, c.send("hello"));
}

test "Client recv before connect returns NotConnected" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.NotConnected, c.recv(&buf));
}

test "Client isConnected reflects state" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    try std.testing.expect(!c.isConnected());

    @atomicStore(bool, &c.connected, true, .release);
    try std.testing.expect(c.isConnected());

    @atomicStore(bool, &c.received_close_notify, true, .release);
    try std.testing.expect(!c.isConnected());
}

test "Client close on not-connected is safe" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    try c.close();
    try std.testing.expect(!c.isConnected());
}

test "Client getVersion and getCipherSuite defaults" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    try std.testing.expectEqual(ProtocolVersion.tls_1_3, c.getVersion());
    try std.testing.expectEqual(CipherSuite.TLS_AES_128_GCM_SHA256, c.getCipherSuite());
}

test "Config custom values" {
    const Crypto = @import("runtime").std.Crypto;

    const config: Config(Crypto) = .{
        .allocator = std.testing.allocator,
        .hostname = "custom.example.com",
        .skip_verify = true,
        .min_version = .tls_1_3,
        .max_version = .tls_1_3,
        .timeout_ms = 5000,
    };

    try std.testing.expectEqual(true, config.skip_verify);
    try std.testing.expectEqual(ProtocolVersion.tls_1_3, config.min_version);
    try std.testing.expectEqual(@as(u32, 5000), config.timeout_ms);
    try std.testing.expectEqualStrings("custom.example.com", config.hostname);
}

test "Client multiple init/deinit cycles" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};

    for (0..5) |_| {
        var c = try Client(TestMockConn, Crypto, Mutex).init(&conn, .{
            .allocator = std.testing.allocator,
            .hostname = "test.com",
        });
        c.deinit();
    }
}

test "Client close sets connected to false" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    @atomicStore(bool, &c.connected, true, .release);
    try std.testing.expect(c.isConnected());

    try c.close();
    try std.testing.expect(!c.isConnected());
}

// ---------------------------------------------------------------------------
// Concurrency tests — use real std.Thread to exercise mutex paths
// ---------------------------------------------------------------------------

const ConcurrentPipeConn = struct {
    mu: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    buf: [65536]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,
    closed: bool = false,

    pub fn read(self: *ConcurrentPipeConn, out: []u8) conn_mod.Error!usize {
        self.mu.lock();
        defer self.mu.unlock();

        const deadline = std.time.nanoTimestamp() + 2_000_000_000;
        while (self.pos >= self.len and !self.closed) {
            if (std.time.nanoTimestamp() >= deadline) return conn_mod.Error.Timeout;
            self.cond.timedWait(&self.mu, 10_000_000) catch {};
        }
        if (self.closed and self.pos >= self.len) return conn_mod.Error.Closed;

        const avail = self.len - self.pos;
        const n = @min(avail, out.len);
        @memcpy(out[0..n], self.buf[self.pos..][0..n]);
        self.pos += n;
        if (self.pos == self.len) {
            self.pos = 0;
            self.len = 0;
        }
        self.cond.broadcast();
        return n;
    }

    pub fn write(self: *ConcurrentPipeConn, data: []const u8) conn_mod.Error!usize {
        self.mu.lock();
        defer self.mu.unlock();

        const deadline = std.time.nanoTimestamp() + 2_000_000_000;
        while (self.len > 0 and !self.closed) {
            if (std.time.nanoTimestamp() >= deadline) return conn_mod.Error.Timeout;
            self.cond.timedWait(&self.mu, 10_000_000) catch {};
        }
        if (self.closed) return conn_mod.Error.Closed;

        const n = @min(data.len, self.buf.len);
        @memcpy(self.buf[0..n], data[0..n]);
        self.len = n;
        self.pos = 0;
        self.cond.broadcast();
        return n;
    }

    pub fn close(self: *ConcurrentPipeConn) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.closed = true;
        self.cond.broadcast();
    }
};

test "concurrent send does not deadlock" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var pipe = ConcurrentPipeConn{};
    var c = try Client(ConcurrentPipeConn, Crypto, Mutex).init(&pipe, .{
        .allocator = std.testing.allocator,
        .hostname = "concurrent.test",
    });
    defer c.deinit();

    @atomicStore(bool, &c.connected, true, .release);

    const key: [16]u8 = [_]u8{0x80} ** 16;
    const iv: [12]u8 = [_]u8{0x81} ** 12;
    const cipher = try record.CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    c.hs.records.setWriteCipher(cipher);
    c.hs.records.version = .tls_1_3;

    const drain_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: *ConcurrentPipeConn) void {
            var drain_buf: [4096]u8 = undefined;
            for (0..200) |_| {
                _ = p.read(&drain_buf) catch break;
            }
        }
    }.run, .{&pipe});

    var send_errors: [2]bool = .{ false, false };
    const threads: [2]std.Thread = .{
        try std.Thread.spawn(.{}, struct {
            fn run(client: *Client(ConcurrentPipeConn, Crypto, Mutex), err_flag: *bool) void {
                for (0..50) |_| {
                    _ = client.send("hello from thread A") catch {
                        err_flag.* = true;
                        return;
                    };
                }
            }
        }.run, .{ &c, &send_errors[0] }),
        try std.Thread.spawn(.{}, struct {
            fn run(client: *Client(ConcurrentPipeConn, Crypto, Mutex), err_flag: *bool) void {
                for (0..50) |_| {
                    _ = client.send("hello from thread B") catch {
                        err_flag.* = true;
                        return;
                    };
                }
            }
        }.run, .{ &c, &send_errors[1] }),
    };

    threads[0].join();
    threads[1].join();
    pipe.close();
    drain_thread.join();
}

test "concurrent recv does not deadlock" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var pipe = ConcurrentPipeConn{};
    var c = try Client(ConcurrentPipeConn, Crypto, Mutex).init(&pipe, .{
        .allocator = std.testing.allocator,
        .hostname = "concurrent.test",
    });
    defer c.deinit();

    @atomicStore(bool, &c.connected, true, .release);

    const key: [16]u8 = [_]u8{0x90} ** 16;
    const iv: [12]u8 = [_]u8{0x91} ** 12;
    const write_cipher = try record.CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    const read_cipher = try record.CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    c.hs.records.setWriteCipher(write_cipher);
    c.hs.records.version = .tls_1_3;

    const feed_thread = try std.Thread.spawn(.{}, struct {
        fn run(client: *Client(ConcurrentPipeConn, Crypto, Mutex)) void {
            for (0..20) |_| {
                _ = client.send("feed data for recv") catch break;
            }
        }
    }.run, .{&c});

    c.hs.records.setReadCipher(read_cipher);

    var recv_buf: [256]u8 = undefined;
    var total_recv: usize = 0;
    for (0..20) |_| {
        const n = c.recv(&recv_buf) catch break;
        total_recv += n;
    }

    feed_thread.join();
    try std.testing.expect(total_recv > 0);
}

test "concurrent send and recv do not deadlock" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var pipe = ConcurrentPipeConn{};
    var c = try Client(ConcurrentPipeConn, Crypto, Mutex).init(&pipe, .{
        .allocator = std.testing.allocator,
        .hostname = "concurrent.test",
    });
    defer c.deinit();

    @atomicStore(bool, &c.connected, true, .release);

    const key: [16]u8 = [_]u8{0xA0} ** 16;
    const iv: [12]u8 = [_]u8{0xA1} ** 12;
    const write_cipher = try record.CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    const read_cipher = try record.CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    c.hs.records.setWriteCipher(write_cipher);
    c.hs.records.setReadCipher(read_cipher);
    c.hs.records.version = .tls_1_3;

    var send_done = std.atomic.Value(bool).init(false);
    var recv_done = std.atomic.Value(bool).init(false);

    const send_thread = try std.Thread.spawn(.{}, struct {
        fn run(client: *Client(ConcurrentPipeConn, Crypto, Mutex), done: *std.atomic.Value(bool)) void {
            defer done.store(true, .release);
            for (0..10) |_| {
                _ = client.send("concurrent data") catch return;
            }
        }
    }.run, .{ &c, &send_done });

    const recv_thread = try std.Thread.spawn(.{}, struct {
        fn run(client: *Client(ConcurrentPipeConn, Crypto, Mutex), done: *std.atomic.Value(bool)) void {
            defer done.store(true, .release);
            var buf: [256]u8 = undefined;
            for (0..10) |_| {
                _ = client.recv(&buf) catch return;
            }
        }
    }.run, .{ &c, &recv_done });

    send_thread.join();
    recv_thread.join();

    try std.testing.expect(send_done.load(.acquire));
    try std.testing.expect(recv_done.load(.acquire));
}

test "concurrent close while send does not deadlock" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var pipe = ConcurrentPipeConn{};
    var c = try Client(ConcurrentPipeConn, Crypto, Mutex).init(&pipe, .{
        .allocator = std.testing.allocator,
        .hostname = "concurrent.test",
    });
    defer c.deinit();

    @atomicStore(bool, &c.connected, true, .release);

    const key: [16]u8 = [_]u8{0xB0} ** 16;
    const iv: [12]u8 = [_]u8{0xB1} ** 12;
    const cipher = try record.CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    c.hs.records.setWriteCipher(cipher);
    c.hs.records.version = .tls_1_3;

    const drain_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: *ConcurrentPipeConn) void {
            var drain_buf: [4096]u8 = undefined;
            for (0..100) |_| {
                _ = p.read(&drain_buf) catch break;
            }
        }
    }.run, .{&pipe});

    const send_thread = try std.Thread.spawn(.{}, struct {
        fn run(client: *Client(ConcurrentPipeConn, Crypto, Mutex)) void {
            for (0..20) |_| {
                _ = client.send("data") catch return;
            }
        }
    }.run, .{&c});

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        std.Thread.yield() catch {};
    }
    c.close() catch {};
    pipe.close();

    send_thread.join();
    drain_thread.join();
    try std.testing.expect(!c.isConnected());
}

test "concurrent close_notify sets received flag" {
    const Crypto = @import("runtime").std.Crypto;
    const Mutex = @import("runtime").std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    @atomicStore(bool, &c.connected, true, .release);
    @atomicStore(bool, &c.received_close_notify, true, .release);

    try std.testing.expect(!c.isConnected());

    try std.testing.expectError(error.ConnectionClosed, c.send("data"));

    var buf: [64]u8 = undefined;
    const n = try c.recv(&buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "mutex lock/unlock cycle under contention" {
    const Mutex = @import("runtime").std.Mutex;

    var mu = Mutex.init();
    defer mu.deinit();

    var counter: u64 = 0;

    const threads: [4]std.Thread = .{
        try std.Thread.spawn(.{}, struct {
            fn run(m: *Mutex, c: *u64) void {
                for (0..1000) |_| {
                    m.lock();
                    c.* += 1;
                    m.unlock();
                }
            }
        }.run, .{ &mu, &counter }),
        try std.Thread.spawn(.{}, struct {
            fn run(m: *Mutex, c: *u64) void {
                for (0..1000) |_| {
                    m.lock();
                    c.* += 1;
                    m.unlock();
                }
            }
        }.run, .{ &mu, &counter }),
        try std.Thread.spawn(.{}, struct {
            fn run(m: *Mutex, c: *u64) void {
                for (0..1000) |_| {
                    m.lock();
                    c.* += 1;
                    m.unlock();
                }
            }
        }.run, .{ &mu, &counter }),
        try std.Thread.spawn(.{}, struct {
            fn run(m: *Mutex, c: *u64) void {
                for (0..1000) |_| {
                    m.lock();
                    c.* += 1;
                    m.unlock();
                }
            }
        }.run, .{ &mu, &counter }),
    };

    for (&threads) |t| t.join();
    try std.testing.expectEqual(@as(u64, 4000), counter);
}
