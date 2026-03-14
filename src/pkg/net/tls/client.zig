const std = @import("std");
const runtime = struct {
    pub const sync = @import("../../../runtime/sync.zig");
    pub const std = @import("../../../runtime/std.zig");
};
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

pub const test_exports = blk: {
    const __test_export_0 = runtime;
    const __test_export_1 = conn_mod;
    const __test_export_2 = common;
    const __test_export_3 = record;
    const __test_export_4 = handshake;
    const __test_export_5 = ProtocolVersion;
    const __test_export_6 = CipherSuite;
    const __test_export_7 = AlertDescription;
    const __test_export_8 = TestMockConn;
    const __test_export_9 = ConcurrentPipeConn;
    break :blk struct {
        pub const runtime = __test_export_0;
        pub const conn_mod = __test_export_1;
        pub const common = __test_export_2;
        pub const record = __test_export_3;
        pub const handshake = __test_export_4;
        pub const ProtocolVersion = __test_export_5;
        pub const CipherSuite = __test_export_6;
        pub const AlertDescription = __test_export_7;
        pub const TestMockConn = __test_export_8;
        pub const ConcurrentPipeConn = __test_export_9;
    };
};
