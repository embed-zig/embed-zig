const std = @import("std");
const runtime = struct {
    pub const std = @import("../../../runtime/std.zig");
};
const common = @import("common.zig");

const ContentType = common.ContentType;
const ProtocolVersion = common.ProtocolVersion;
const CipherSuite = common.CipherSuite;
const AlertDescription = common.AlertDescription;
const AlertLevel = common.AlertLevel;

pub const RecordHeader = struct {
    content_type: ContentType,
    legacy_version: ProtocolVersion,
    length: u16,

    pub const SIZE = 5;

    pub fn parse(buf: []const u8) !RecordHeader {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return RecordHeader{
            .content_type = @enumFromInt(buf[0]),
            .legacy_version = @enumFromInt(std.mem.readInt(u16, buf[1..3], .big)),
            .length = std.mem.readInt(u16, buf[3..5], .big),
        };
    }

    pub fn serialize(self: RecordHeader, buf: []u8) !void {
        if (buf.len < SIZE) return error.BufferTooSmall;
        buf[0] = @intFromEnum(self.content_type);
        std.mem.writeInt(u16, buf[1..3], @intFromEnum(self.legacy_version), .big);
        std.mem.writeInt(u16, buf[3..5], self.length, .big);
    }
};

pub fn CipherState(comptime Crypto: type) type {
    return union(enum) {
        none,
        aes_128_gcm: AesGcmState(Crypto, 16),
        aes_256_gcm: AesGcmState(Crypto, 32),
        chacha20_poly1305: ChaChaState(Crypto),

        const Self = @This();

        pub fn init(suite: CipherSuite, key: []const u8, iv: []const u8) !Self {
            return switch (suite) {
                .TLS_AES_128_GCM_SHA256,
                .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                => .{ .aes_128_gcm = try AesGcmState(Crypto, 16).init(key, iv) },

                .TLS_AES_256_GCM_SHA384,
                .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
                => .{ .aes_256_gcm = try AesGcmState(Crypto, 32).init(key, iv) },

                .TLS_CHACHA20_POLY1305_SHA256,
                .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                => .{ .chacha20_poly1305 = try ChaChaState(Crypto).init(key, iv) },

                else => return error.UnsupportedCipherSuite,
            };
        }
    };
}

fn AesGcmState(comptime Crypto: type, comptime key_len: usize) type {
    return struct {
        key: [key_len]u8,
        iv: [12]u8,

        const Self = @This();
        const AEAD = if (key_len == 16) Crypto.Aes128Gcm else Crypto.Aes256Gcm;

        pub fn init(key: []const u8, iv: []const u8) !Self {
            if (key.len != key_len) return error.InvalidKeyLength;
            if (iv.len != 12) return error.InvalidIvLength;
            var self: Self = undefined;
            @memcpy(&self.key, key);
            @memcpy(&self.iv, iv);
            return self;
        }

        pub fn encrypt(self: *Self, ciphertext: []u8, tag: *[16]u8, plaintext: []const u8, additional_data: []const u8, seq_num: u64) void {
            const nonce = self.computeNonce(seq_num);
            AEAD.encryptStatic(ciphertext, tag, plaintext, additional_data, nonce, self.key);
        }

        pub fn encryptTls12(self: *Self, ciphertext: []u8, tag: *[16]u8, plaintext: []const u8, additional_data: []const u8, explicit_nonce: *const [8]u8) void {
            var nonce: [12]u8 = undefined;
            @memcpy(nonce[0..4], self.iv[0..4]);
            @memcpy(nonce[4..12], explicit_nonce);
            AEAD.encryptStatic(ciphertext, tag, plaintext, additional_data, nonce, self.key);
        }

        pub fn decrypt(self: *Self, plaintext: []u8, ciphertext: []const u8, tag: [16]u8, additional_data: []const u8, seq_num: u64) !void {
            const nonce = self.computeNonce(seq_num);
            try AEAD.decryptStatic(plaintext, ciphertext, tag, additional_data, nonce, self.key);
        }

        pub fn decryptTls12(self: *Self, plaintext: []u8, ciphertext: []const u8, tag: [16]u8, additional_data: []const u8, explicit_nonce: *const [8]u8) !void {
            var nonce: [12]u8 = undefined;
            @memcpy(nonce[0..4], self.iv[0..4]);
            @memcpy(nonce[4..12], explicit_nonce);
            try AEAD.decryptStatic(plaintext, ciphertext, tag, additional_data, nonce, self.key);
        }

        fn computeNonce(self: *Self, seq_num: u64) [12]u8 {
            var nonce = self.iv;
            const seq_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, seq_num));
            for (0..8) |i| {
                nonce[4 + i] ^= seq_bytes[i];
            }
            return nonce;
        }
    };
}

fn ChaChaState(comptime Crypto: type) type {
    return struct {
        key: [32]u8,
        iv: [12]u8,

        const Self = @This();
        const AEAD = Crypto.ChaCha20Poly1305;

        pub fn init(key: []const u8, iv: []const u8) !Self {
            if (key.len != 32) return error.InvalidKeyLength;
            if (iv.len != 12) return error.InvalidIvLength;
            var self: Self = undefined;
            @memcpy(&self.key, key);
            @memcpy(&self.iv, iv);
            return self;
        }

        pub fn encrypt(self: *Self, ciphertext: []u8, tag: *[16]u8, plaintext: []const u8, additional_data: []const u8, seq_num: u64) void {
            const nonce = self.computeNonce(seq_num);
            AEAD.encryptStatic(ciphertext, tag, plaintext, additional_data, nonce, self.key);
        }

        pub fn encryptTls12(self: *Self, ciphertext: []u8, tag: *[16]u8, plaintext: []const u8, additional_data: []const u8, explicit_nonce: *const [8]u8) void {
            var nonce: [12]u8 = self.iv;
            for (0..8) |i| {
                nonce[4 + i] ^= explicit_nonce[i];
            }
            AEAD.encryptStatic(ciphertext, tag, plaintext, additional_data, nonce, self.key);
        }

        pub fn decrypt(self: *Self, plaintext: []u8, ciphertext: []const u8, tag: [16]u8, additional_data: []const u8, seq_num: u64) !void {
            const nonce = self.computeNonce(seq_num);
            try AEAD.decryptStatic(plaintext, ciphertext, tag, additional_data, nonce, self.key);
        }

        pub fn decryptTls12(self: *Self, plaintext: []u8, ciphertext: []const u8, tag: [16]u8, additional_data: []const u8, explicit_nonce: *const [8]u8) !void {
            var nonce: [12]u8 = self.iv;
            for (0..8) |i| {
                nonce[4 + i] ^= explicit_nonce[i];
            }
            try AEAD.decryptStatic(plaintext, ciphertext, tag, additional_data, nonce, self.key);
        }

        fn computeNonce(self: *Self, seq_num: u64) [12]u8 {
            var nonce = self.iv;
            const seq_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, seq_num));
            for (0..8) |i| {
                nonce[4 + i] ^= seq_bytes[i];
            }
            return nonce;
        }
    };
}

pub const RecordError = error{
    BufferTooSmall,
    InvalidKeyLength,
    InvalidIvLength,
    UnsupportedCipherSuite,
    RecordTooLarge,
    DecryptionFailed,
    BadRecordMac,
    UnexpectedRecord,
};

/// TLS Record Layer — reads/writes TLS records over a `Conn`.
///
/// `Conn` must satisfy the `net.conn.from` contract (`read`/`write`/`close`).
pub fn RecordLayer(comptime Conn: type, comptime Crypto: type) type {
    return struct {
        conn: *Conn,
        read_cipher: CipherState(Crypto),
        write_cipher: CipherState(Crypto),
        read_seq: u64,
        write_seq: u64,
        version: ProtocolVersion,

        const Self = @This();

        pub fn init(conn: *Conn) Self {
            return .{
                .conn = conn,
                .read_cipher = .none,
                .write_cipher = .none,
                .read_seq = 0,
                .write_seq = 0,
                .version = .tls_1_2,
            };
        }

        pub fn setReadCipher(self: *Self, cipher: CipherState(Crypto)) void {
            self.read_cipher = cipher;
            self.read_seq = 0;
        }

        pub fn setWriteCipher(self: *Self, cipher: CipherState(Crypto)) void {
            self.write_cipher = cipher;
            self.write_seq = 0;
        }

        fn connWrite(self: *Self, data: []const u8) !void {
            var written: usize = 0;
            while (written < data.len) {
                const n = self.conn.write(data[written..]) catch return error.UnexpectedRecord;
                if (n == 0) return error.UnexpectedRecord;
                written += n;
            }
        }

        fn connRead(self: *Self, buf: []u8) !usize {
            return self.conn.read(buf) catch return error.UnexpectedRecord;
        }

        pub fn writeRecord(self: *Self, content_type: ContentType, plaintext: []const u8, buffer: []u8) !usize {
            if (plaintext.len > common.MAX_PLAINTEXT_LEN) {
                return error.RecordTooLarge;
            }

            switch (self.write_cipher) {
                .none => {
                    const total_len = RecordHeader.SIZE + plaintext.len;
                    if (buffer.len < total_len) return error.BufferTooSmall;

                    const header = RecordHeader{
                        .content_type = content_type,
                        .legacy_version = self.version,
                        .length = @intCast(plaintext.len),
                    };
                    try header.serialize(buffer[0..RecordHeader.SIZE]);
                    @memcpy(buffer[RecordHeader.SIZE..][0..plaintext.len], plaintext);

                    try self.connWrite(buffer[0..total_len]);
                    return total_len;
                },
                inline .aes_128_gcm, .aes_256_gcm, .chacha20_poly1305 => |*cipher| {
                    if (self.version == .tls_1_3) {
                        const inner_len = plaintext.len + 1;
                        const ciphertext_len = inner_len + 16;
                        const total_len = RecordHeader.SIZE + ciphertext_len;

                        if (buffer.len < total_len) return error.BufferTooSmall;

                        const header = RecordHeader{
                            .content_type = .application_data,
                            .legacy_version = .tls_1_2,
                            .length = @intCast(ciphertext_len),
                        };
                        try header.serialize(buffer[0..RecordHeader.SIZE]);

                        var inner_plaintext: [common.MAX_PLAINTEXT_LEN + 1]u8 = undefined;
                        @memcpy(inner_plaintext[0..plaintext.len], plaintext);
                        inner_plaintext[plaintext.len] = @intFromEnum(content_type);

                        const ad = buffer[0..RecordHeader.SIZE];

                        var tag: [16]u8 = undefined;
                        cipher.encrypt(
                            buffer[RecordHeader.SIZE..][0..inner_len],
                            &tag,
                            inner_plaintext[0..inner_len],
                            ad,
                            self.write_seq,
                        );
                        @memcpy(buffer[RecordHeader.SIZE + inner_len ..][0..16], &tag);

                        self.write_seq += 1;
                        try self.connWrite(buffer[0..total_len]);
                        return total_len;
                    } else {
                        const explicit_nonce_len: usize = 8;
                        const record_len = explicit_nonce_len + plaintext.len + 16;
                        const total_len = RecordHeader.SIZE + record_len;

                        if (buffer.len < total_len) return error.BufferTooSmall;

                        const header = RecordHeader{
                            .content_type = content_type,
                            .legacy_version = self.version,
                            .length = @intCast(record_len),
                        };
                        try header.serialize(buffer[0..RecordHeader.SIZE]);

                        var explicit_nonce: [8]u8 = undefined;
                        std.mem.writeInt(u64, &explicit_nonce, self.write_seq, .big);
                        @memcpy(buffer[RecordHeader.SIZE..][0..8], &explicit_nonce);

                        var ad: [13]u8 = undefined;
                        std.mem.writeInt(u64, ad[0..8], self.write_seq, .big);
                        ad[8] = @intFromEnum(content_type);
                        std.mem.writeInt(u16, ad[9..11], @intFromEnum(self.version), .big);
                        std.mem.writeInt(u16, ad[11..13], @intCast(plaintext.len), .big);

                        var tag: [16]u8 = undefined;
                        cipher.encryptTls12(
                            buffer[RecordHeader.SIZE + 8 ..][0..plaintext.len],
                            &tag,
                            plaintext,
                            &ad,
                            &explicit_nonce,
                        );
                        @memcpy(buffer[RecordHeader.SIZE + 8 + plaintext.len ..][0..16], &tag);

                        self.write_seq += 1;
                        try self.connWrite(buffer[0..total_len]);
                        return total_len;
                    }
                },
            }
        }

        pub fn readRecord(self: *Self, buffer: []u8, plaintext_out: []u8) !struct { content_type: ContentType, length: usize } {
            var header_buf: [RecordHeader.SIZE]u8 = undefined;
            var bytes_read: usize = 0;
            while (bytes_read < RecordHeader.SIZE) {
                const n = try self.connRead(header_buf[bytes_read..]);
                if (n == 0) return error.UnexpectedRecord;
                bytes_read += n;
            }

            const header = try RecordHeader.parse(&header_buf);
            if (header.length > common.MAX_CIPHERTEXT_LEN) {
                return error.RecordTooLarge;
            }

            if (buffer.len < header.length) return error.BufferTooSmall;
            bytes_read = 0;
            while (bytes_read < header.length) {
                const n = try self.connRead(buffer[bytes_read..header.length]);
                if (n == 0) return error.UnexpectedRecord;
                bytes_read += n;
            }

            const record_body = buffer[0..header.length];

            if (header.content_type == .change_cipher_spec) {
                if (plaintext_out.len < header.length) return error.BufferTooSmall;
                @memcpy(plaintext_out[0..header.length], record_body);
                return .{ .content_type = header.content_type, .length = header.length };
            }

            switch (self.read_cipher) {
                .none => {
                    if (plaintext_out.len < header.length) return error.BufferTooSmall;
                    @memcpy(plaintext_out[0..header.length], record_body);
                    return .{ .content_type = header.content_type, .length = header.length };
                },
                inline .aes_128_gcm, .aes_256_gcm, .chacha20_poly1305 => |*cipher| {
                    if (self.version == .tls_1_3) {
                        if (header.length < 17) return error.BadRecordMac;

                        const ciphertext_len = header.length - 16;
                        const ciphertext = record_body[0..ciphertext_len];
                        const tag = record_body[ciphertext_len..][0..16].*;

                        if (plaintext_out.len < ciphertext_len) return error.BufferTooSmall;

                        cipher.decrypt(
                            plaintext_out[0..ciphertext_len],
                            ciphertext,
                            tag,
                            &header_buf,
                            self.read_seq,
                        ) catch return error.BadRecordMac;

                        self.read_seq += 1;

                        var inner_len = ciphertext_len;
                        while (inner_len > 0 and plaintext_out[inner_len - 1] == 0) {
                            inner_len -= 1;
                        }
                        if (inner_len == 0) return error.DecryptionFailed;

                        inner_len -= 1;
                        const inner_content_type: ContentType = @enumFromInt(plaintext_out[inner_len]);

                        return .{ .content_type = inner_content_type, .length = inner_len };
                    } else {
                        if (header.length < 8 + 16 + 1) return error.BadRecordMac;

                        const explicit_nonce = record_body[0..8];
                        const ciphertext_len = header.length - 8 - 16;
                        const ciphertext = record_body[8..][0..ciphertext_len];
                        const tag = record_body[8 + ciphertext_len ..][0..16].*;

                        if (plaintext_out.len < ciphertext_len) return error.BufferTooSmall;

                        var ad: [13]u8 = undefined;
                        std.mem.writeInt(u64, ad[0..8], self.read_seq, .big);
                        ad[8] = @intFromEnum(header.content_type);
                        std.mem.writeInt(u16, ad[9..11], @intFromEnum(header.legacy_version), .big);
                        std.mem.writeInt(u16, ad[11..13], @intCast(ciphertext_len), .big);

                        cipher.decryptTls12(
                            plaintext_out[0..ciphertext_len],
                            ciphertext,
                            tag,
                            &ad,
                            explicit_nonce,
                        ) catch return error.BadRecordMac;

                        self.read_seq += 1;

                        return .{ .content_type = header.content_type, .length = ciphertext_len };
                    }
                },
            }
        }

        pub fn sendAlert(self: *Self, level: AlertLevel, description: AlertDescription, buffer: []u8) !void {
            const alert_data = [_]u8{
                @intFromEnum(level),
                @intFromEnum(description),
            };
            _ = try self.writeRecord(.alert, &alert_data, buffer);
        }
    };
}

test "RecordHeader parse and serialize" {
    const header = RecordHeader{
        .content_type = .handshake,
        .legacy_version = .tls_1_2,
        .length = 256,
    };

    var buf: [5]u8 = undefined;
    try header.serialize(&buf);

    const parsed = try RecordHeader.parse(&buf);
    try std.testing.expectEqual(header.content_type, parsed.content_type);
    try std.testing.expectEqual(header.legacy_version, parsed.legacy_version);
    try std.testing.expectEqual(header.length, parsed.length);
}

test "CipherState initialization" {
    const Crypto = runtime.std.Crypto;

    const key_128: [16]u8 = [_]u8{0} ** 16;
    const iv: [12]u8 = [_]u8{0} ** 12;

    const state = try CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key_128, &iv);
    try std.testing.expect(state == .aes_128_gcm);
}

test "AES-128-GCM encrypt/decrypt round trip" {
    const Crypto = runtime.std.Crypto;

    const key: [16]u8 = [_]u8{0x01} ** 16;
    const iv: [12]u8 = [_]u8{0x02} ** 12;
    const plaintext = "Hello, TLS Record Layer!";
    const ad = "additional data";

    var state = try AesGcmState(Crypto, 16).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 0);

    var decrypted: [plaintext.len]u8 = undefined;
    try state.decrypt(&decrypted, &ciphertext, tag, ad, 0);

    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "ChaCha20-Poly1305 encrypt/decrypt round trip" {
    const Crypto = runtime.std.Crypto;

    const key: [32]u8 = [_]u8{0x05} ** 32;
    const iv: [12]u8 = [_]u8{0x06} ** 12;
    const plaintext = "ChaCha20-Poly1305 record test";
    const ad = "associated data";

    var state = try ChaChaState(Crypto).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 0);

    var decrypted: [plaintext.len]u8 = undefined;
    try state.decrypt(&decrypted, &ciphertext, tag, ad, 0);

    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "Decryption with wrong sequence number fails" {
    const Crypto = runtime.std.Crypto;

    const key: [16]u8 = [_]u8{0x07} ** 16;
    const iv: [12]u8 = [_]u8{0x08} ** 12;
    const plaintext = "Sequence number test";
    const ad = "aad";

    var state = try AesGcmState(Crypto, 16).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 5);

    var decrypted: [plaintext.len]u8 = undefined;
    const result = state.decrypt(&decrypted, &ciphertext, tag, ad, 6);
    try std.testing.expectError(error.AuthenticationFailed, result);

    try state.decrypt(&decrypted, &ciphertext, tag, ad, 5);
    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "CipherState unsupported cipher suite" {
    const Crypto = runtime.std.Crypto;

    const key: [16]u8 = [_]u8{0} ** 16;
    const iv: [12]u8 = [_]u8{0} ** 12;

    const unknown_suite: CipherSuite = @enumFromInt(0xFFFF);
    const result = CipherState(Crypto).init(unknown_suite, &key, &iv);
    try std.testing.expectError(error.UnsupportedCipherSuite, result);
}

test "AES-256-GCM encrypt/decrypt round trip" {
    const Crypto = runtime.std.Crypto;

    const key: [32]u8 = [_]u8{0xAB} ** 32;
    const iv: [12]u8 = [_]u8{0xCD} ** 12;
    const plaintext = "AES-256-GCM test payload for TLS";
    const ad = "aes256 additional data";

    var state = try AesGcmState(Crypto, 32).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 0);

    var decrypted: [plaintext.len]u8 = undefined;
    try state.decrypt(&decrypted, &ciphertext, tag, ad, 0);
    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "CipherState init all supported suites" {
    const Crypto = runtime.std.Crypto;

    const key16: [16]u8 = [_]u8{0} ** 16;
    const key32: [32]u8 = [_]u8{0} ** 32;
    const iv: [12]u8 = [_]u8{0} ** 12;

    const suites_16 = [_]CipherSuite{
        .TLS_AES_128_GCM_SHA256,
        .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
        .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
    };
    for (suites_16) |suite| {
        const s = try CipherState(Crypto).init(suite, &key16, &iv);
        try std.testing.expect(s == .aes_128_gcm);
    }

    const suites_32_aes = [_]CipherSuite{
        .TLS_AES_256_GCM_SHA384,
        .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
        .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
    };
    for (suites_32_aes) |suite| {
        const s = try CipherState(Crypto).init(suite, &key32, &iv);
        try std.testing.expect(s == .aes_256_gcm);
    }

    const suites_chacha = [_]CipherSuite{
        .TLS_CHACHA20_POLY1305_SHA256,
        .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
        .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
    };
    for (suites_chacha) |suite| {
        const s = try CipherState(Crypto).init(suite, &key32, &iv);
        try std.testing.expect(s == .chacha20_poly1305);
    }
}

test "AesGcmState invalid key length" {
    const Crypto = runtime.std.Crypto;

    const bad_key: [15]u8 = [_]u8{0} ** 15;
    const iv: [12]u8 = [_]u8{0} ** 12;
    try std.testing.expectError(error.InvalidKeyLength, AesGcmState(Crypto, 16).init(&bad_key, &iv));
}

test "AesGcmState invalid IV length" {
    const Crypto = runtime.std.Crypto;

    const key: [16]u8 = [_]u8{0} ** 16;
    const bad_iv: [8]u8 = [_]u8{0} ** 8;
    try std.testing.expectError(error.InvalidIvLength, AesGcmState(Crypto, 16).init(&key, &bad_iv));
}

test "ChaChaState invalid key length" {
    const Crypto = runtime.std.Crypto;

    const bad_key: [16]u8 = [_]u8{0} ** 16;
    const iv: [12]u8 = [_]u8{0} ** 12;
    try std.testing.expectError(error.InvalidKeyLength, ChaChaState(Crypto).init(&bad_key, &iv));
}

test "ChaChaState invalid IV length" {
    const Crypto = runtime.std.Crypto;

    const key: [32]u8 = [_]u8{0} ** 32;
    const bad_iv: [8]u8 = [_]u8{0} ** 8;
    try std.testing.expectError(error.InvalidIvLength, ChaChaState(Crypto).init(&key, &bad_iv));
}

test "AES-128-GCM TLS 1.2 explicit nonce encrypt/decrypt" {
    const Crypto = runtime.std.Crypto;

    const key: [16]u8 = [_]u8{0x11} ** 16;
    const iv: [12]u8 = [_]u8{0x22} ** 12;
    const plaintext = "TLS 1.2 explicit nonce test";
    const ad = "tls12 aad";
    var explicit_nonce: [8]u8 = undefined;
    std.mem.writeInt(u64, &explicit_nonce, 42, .big);

    var state = try AesGcmState(Crypto, 16).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encryptTls12(&ciphertext, &tag, plaintext, ad, &explicit_nonce);

    var decrypted: [plaintext.len]u8 = undefined;
    try state.decryptTls12(&decrypted, &ciphertext, tag, ad, &explicit_nonce);
    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "ChaCha20 TLS 1.2 explicit nonce encrypt/decrypt" {
    const Crypto = runtime.std.Crypto;

    const key: [32]u8 = [_]u8{0x33} ** 32;
    const iv: [12]u8 = [_]u8{0x44} ** 12;
    const plaintext = "ChaCha TLS 1.2 nonce test";
    const ad = "chacha tls12 aad";
    var explicit_nonce: [8]u8 = undefined;
    std.mem.writeInt(u64, &explicit_nonce, 99, .big);

    var state = try ChaChaState(Crypto).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encryptTls12(&ciphertext, &tag, plaintext, ad, &explicit_nonce);

    var decrypted: [plaintext.len]u8 = undefined;
    try state.decryptTls12(&decrypted, &ciphertext, tag, ad, &explicit_nonce);
    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "Decryption with tampered ciphertext fails" {
    const Crypto = runtime.std.Crypto;

    const key: [16]u8 = [_]u8{0xAA} ** 16;
    const iv: [12]u8 = [_]u8{0xBB} ** 12;
    const plaintext = "tamper test";
    const ad = "aad";

    var state = try AesGcmState(Crypto, 16).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 0);

    ciphertext[0] ^= 0xFF;

    var decrypted: [plaintext.len]u8 = undefined;
    try std.testing.expectError(error.AuthenticationFailed, state.decrypt(&decrypted, &ciphertext, tag, ad, 0));
}

test "Decryption with tampered tag fails" {
    const Crypto = runtime.std.Crypto;

    const key: [32]u8 = [_]u8{0xCC} ** 32;
    const iv: [12]u8 = [_]u8{0xDD} ** 12;
    const plaintext = "tag tamper test";
    const ad = "aad";

    var state = try AesGcmState(Crypto, 32).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 0);

    tag[0] ^= 0xFF;

    var decrypted: [plaintext.len]u8 = undefined;
    try std.testing.expectError(error.AuthenticationFailed, state.decrypt(&decrypted, &ciphertext, tag, ad, 0));
}

test "Decryption with wrong additional data fails" {
    const Crypto = runtime.std.Crypto;

    const key: [16]u8 = [_]u8{0xEE} ** 16;
    const iv: [12]u8 = [_]u8{0xFF} ** 12;
    const plaintext = "ad tamper test";

    var state = try AesGcmState(Crypto, 16).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, "correct ad", 0);

    var decrypted: [plaintext.len]u8 = undefined;
    try std.testing.expectError(error.AuthenticationFailed, state.decrypt(&decrypted, &ciphertext, tag, "wrong ad", 0));
}

test "Nonce computation XORs sequence number correctly" {
    const Crypto = runtime.std.Crypto;

    const key: [16]u8 = [_]u8{0} ** 16;
    const iv: [12]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const plaintext = "nonce xor test";
    const ad = "aad";

    var state0 = try AesGcmState(Crypto, 16).init(&key, &iv);
    var state1 = try AesGcmState(Crypto, 16).init(&key, &iv);

    var ct0: [plaintext.len]u8 = undefined;
    var tag0: [16]u8 = undefined;
    state0.encrypt(&ct0, &tag0, plaintext, ad, 0);

    var ct1: [plaintext.len]u8 = undefined;
    var tag1: [16]u8 = undefined;
    state1.encrypt(&ct1, &tag1, plaintext, ad, 1);

    try std.testing.expect(!std.mem.eql(u8, &ct0, &ct1));
}

test "RecordHeader parse too small buffer" {
    const buf: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, RecordHeader.parse(&buf));
}

test "RecordHeader serialize too small buffer" {
    const header = RecordHeader{
        .content_type = .handshake,
        .legacy_version = .tls_1_2,
        .length = 0,
    };
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, header.serialize(&buf));
}

test "RecordHeader all content types" {
    const types = [_]ContentType{ .change_cipher_spec, .alert, .handshake, .application_data };
    for (types) |ct| {
        const header = RecordHeader{
            .content_type = ct,
            .legacy_version = .tls_1_3,
            .length = 100,
        };
        var buf: [5]u8 = undefined;
        try header.serialize(&buf);
        const parsed = try RecordHeader.parse(&buf);
        try std.testing.expectEqual(ct, parsed.content_type);
    }
}

test "RecordHeader max length" {
    const header = RecordHeader{
        .content_type = .application_data,
        .legacy_version = .tls_1_2,
        .length = 0xFFFF,
    };
    var buf: [5]u8 = undefined;
    try header.serialize(&buf);
    const parsed = try RecordHeader.parse(&buf);
    try std.testing.expectEqual(@as(u16, 0xFFFF), parsed.length);
}

const MockConn = struct {
    write_buf: [16384]u8 = undefined,
    write_len: usize = 0,
    read_buf: [16384]u8 = undefined,
    read_len: usize = 0,
    read_pos: usize = 0,
    closed: bool = false,

    const conn_mod = @import("../conn.zig");

    pub fn read(self: *MockConn, buf: []u8) conn_mod.Error!usize {
        if (self.closed) return conn_mod.Error.Closed;
        if (self.read_pos >= self.read_len) return conn_mod.Error.ReadFailed;
        const avail = self.read_len - self.read_pos;
        const n = @min(avail, buf.len);
        @memcpy(buf[0..n], self.read_buf[self.read_pos..][0..n]);
        self.read_pos += n;
        return n;
    }

    pub fn write(self: *MockConn, data: []const u8) conn_mod.Error!usize {
        if (self.closed) return conn_mod.Error.Closed;
        const space = self.write_buf.len - self.write_len;
        const n = @min(space, data.len);
        if (n == 0) return conn_mod.Error.WriteFailed;
        @memcpy(self.write_buf[self.write_len..][0..n], data[0..n]);
        self.write_len += n;
        return n;
    }

    pub fn close(self: *MockConn) void {
        self.closed = true;
    }

    fn feedData(self: *MockConn, data: []const u8) void {
        @memcpy(self.read_buf[0..data.len], data);
        self.read_len = data.len;
        self.read_pos = 0;
    }
};

test "RecordLayer plaintext write and read round trip" {
    const Crypto = runtime.std.Crypto;

    var mock = MockConn{};
    var rl = RecordLayer(MockConn, Crypto).init(&mock);

    const plaintext = "hello record layer";
    var buffer: [256]u8 = undefined;
    const written = try rl.writeRecord(.application_data, plaintext, &buffer);
    try std.testing.expect(written > 0);

    mock.feedData(mock.write_buf[0..mock.write_len]);
    mock.write_len = 0;

    var read_buf: [256]u8 = undefined;
    var pt_out: [256]u8 = undefined;
    const result = try rl.readRecord(&read_buf, &pt_out);
    try std.testing.expectEqual(ContentType.application_data, result.content_type);
    try std.testing.expectEqual(plaintext.len, result.length);
    try std.testing.expectEqualSlices(u8, plaintext, pt_out[0..result.length]);
}

test "RecordLayer encrypted TLS 1.3 write and read round trip" {
    const Crypto = runtime.std.Crypto;

    var mock = MockConn{};
    var rl = RecordLayer(MockConn, Crypto).init(&mock);
    rl.version = .tls_1_3;

    const key: [16]u8 = [_]u8{0x42} ** 16;
    const iv: [12]u8 = [_]u8{0x43} ** 12;
    const write_cipher = try CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    const read_cipher = try CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    rl.setWriteCipher(write_cipher);

    const plaintext = "encrypted TLS 1.3 payload";
    var buffer: [512]u8 = undefined;
    _ = try rl.writeRecord(.application_data, plaintext, &buffer);

    mock.feedData(mock.write_buf[0..mock.write_len]);
    mock.write_len = 0;

    rl.setReadCipher(read_cipher);

    var read_buf: [512]u8 = undefined;
    var pt_out: [512]u8 = undefined;
    const result = try rl.readRecord(&read_buf, &pt_out);
    try std.testing.expectEqual(ContentType.application_data, result.content_type);
    try std.testing.expectEqual(plaintext.len, result.length);
    try std.testing.expectEqualSlices(u8, plaintext, pt_out[0..result.length]);
}

test "RecordLayer encrypted TLS 1.2 write and read round trip" {
    const Crypto = runtime.std.Crypto;

    var mock = MockConn{};
    var rl = RecordLayer(MockConn, Crypto).init(&mock);
    rl.version = .tls_1_2;

    const key: [16]u8 = [_]u8{0x50} ** 16;
    const iv: [12]u8 = [_]u8{0x51} ** 12;
    const write_cipher = try CipherState(Crypto).init(.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, &key, &iv);
    const read_cipher = try CipherState(Crypto).init(.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, &key, &iv);
    rl.setWriteCipher(write_cipher);

    const plaintext = "encrypted TLS 1.2 payload";
    var buffer: [512]u8 = undefined;
    _ = try rl.writeRecord(.application_data, plaintext, &buffer);

    mock.feedData(mock.write_buf[0..mock.write_len]);
    mock.write_len = 0;

    rl.setReadCipher(read_cipher);

    var read_buf: [512]u8 = undefined;
    var pt_out: [512]u8 = undefined;
    const result = try rl.readRecord(&read_buf, &pt_out);
    try std.testing.expectEqual(ContentType.application_data, result.content_type);
    try std.testing.expectEqual(plaintext.len, result.length);
    try std.testing.expectEqualSlices(u8, plaintext, pt_out[0..result.length]);
}

test "RecordLayer rejects record too large" {
    const Crypto = runtime.std.Crypto;

    var mock = MockConn{};
    var rl = RecordLayer(MockConn, Crypto).init(&mock);

    var big_data: [common.MAX_PLAINTEXT_LEN + 1]u8 = undefined;
    @memset(&big_data, 0x41);
    var buffer: [common.MAX_CIPHERTEXT_LEN + 256]u8 = undefined;
    try std.testing.expectError(error.RecordTooLarge, rl.writeRecord(.application_data, &big_data, &buffer));
}

test "RecordLayer sendAlert" {
    const Crypto = runtime.std.Crypto;

    var mock = MockConn{};
    var rl = RecordLayer(MockConn, Crypto).init(&mock);

    var buffer: [256]u8 = undefined;
    try rl.sendAlert(.fatal, .handshake_failure, &buffer);

    try std.testing.expect(mock.write_len > 0);

    mock.feedData(mock.write_buf[0..mock.write_len]);
    var read_buf: [256]u8 = undefined;
    var pt_out: [256]u8 = undefined;
    const result = try rl.readRecord(&read_buf, &pt_out);
    try std.testing.expectEqual(ContentType.alert, result.content_type);
    try std.testing.expectEqual(@as(usize, 2), result.length);
    try std.testing.expectEqual(@as(u8, @intFromEnum(common.AlertLevel.fatal)), pt_out[0]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(common.AlertDescription.handshake_failure)), pt_out[1]);
}

test "RecordLayer change_cipher_spec passthrough" {
    const Crypto = runtime.std.Crypto;

    var mock = MockConn{};
    var rl = RecordLayer(MockConn, Crypto).init(&mock);

    const ccs_payload = [_]u8{1};
    var buffer: [256]u8 = undefined;
    _ = try rl.writeRecord(.change_cipher_spec, &ccs_payload, &buffer);

    mock.feedData(mock.write_buf[0..mock.write_len]);
    mock.write_len = 0;

    var read_buf: [256]u8 = undefined;
    var pt_out: [256]u8 = undefined;
    const result = try rl.readRecord(&read_buf, &pt_out);
    try std.testing.expectEqual(ContentType.change_cipher_spec, result.content_type);
    try std.testing.expectEqual(@as(usize, 1), result.length);
    try std.testing.expectEqual(@as(u8, 1), pt_out[0]);
}

test "RecordLayer sequence numbers increment" {
    const Crypto = runtime.std.Crypto;

    var mock = MockConn{};
    var rl = RecordLayer(MockConn, Crypto).init(&mock);
    rl.version = .tls_1_3;

    const key: [16]u8 = [_]u8{0x60} ** 16;
    const iv: [12]u8 = [_]u8{0x61} ** 12;
    const cipher = try CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    rl.setWriteCipher(cipher);

    try std.testing.expectEqual(@as(u64, 0), rl.write_seq);

    var buffer: [512]u8 = undefined;
    _ = try rl.writeRecord(.application_data, "msg1", &buffer);
    try std.testing.expectEqual(@as(u64, 1), rl.write_seq);

    mock.write_len = 0;
    _ = try rl.writeRecord(.application_data, "msg2", &buffer);
    try std.testing.expectEqual(@as(u64, 2), rl.write_seq);
}

test "RecordLayer setWriteCipher resets sequence" {
    const Crypto = runtime.std.Crypto;

    var mock = MockConn{};
    var rl = RecordLayer(MockConn, Crypto).init(&mock);
    rl.version = .tls_1_3;

    const key: [16]u8 = [_]u8{0x70} ** 16;
    const iv: [12]u8 = [_]u8{0x71} ** 12;
    var cipher = try CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    rl.setWriteCipher(cipher);

    var buffer: [512]u8 = undefined;
    _ = try rl.writeRecord(.application_data, "msg", &buffer);
    try std.testing.expectEqual(@as(u64, 1), rl.write_seq);

    cipher = try CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    rl.setWriteCipher(cipher);
    try std.testing.expectEqual(@as(u64, 0), rl.write_seq);
}
