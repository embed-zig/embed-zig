const time_mod = @import("time");
const testing_api = @import("testing");

pub fn make(comptime std: type) type {
    const common = @import("common.zig").make(std);
    const crypto = std.crypto;
    const mem = std.mem;

    return struct {
        pub const RecordError = error{
            BufferTooSmall,
            InvalidKeyLength,
            InvalidIvLength,
            UnsupportedCipherSuite,
            RecordTooLarge,
            DecryptionFailed,
            BadRecordMac,
            ConnectionRefused,
            ConnectionReset,
            BrokenPipe,
            UnexpectedRecord,
            TimedOut,
        };

        pub const ReadRecordResult = struct {
            content_type: common.ContentType,
            length: usize,
        };

        pub fn CipherState() type {
            return union(enum) {
                none,
                aes_128_gcm: AesGcmState(16),
                aes_256_gcm: AesGcmState(32),
                chacha20_poly1305: ChaChaState,

                const Self = @This();

                pub fn init(suite: common.CipherSuite, key: []const u8, iv: []const u8) RecordError!Self {
                    return switch (suite) {
                        .TLS_AES_128_GCM_SHA256,
                        .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                        .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                        => .{ .aes_128_gcm = try AesGcmState(16).init(key, iv) },

                        .TLS_AES_256_GCM_SHA384,
                        .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                        .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
                        => .{ .aes_256_gcm = try AesGcmState(32).init(key, iv) },

                        .TLS_CHACHA20_POLY1305_SHA256,
                        .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                        .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                        => .{ .chacha20_poly1305 = try ChaChaState.init(key, iv) },

                        else => return error.UnsupportedCipherSuite,
                    };
                }
            };
        }

        pub fn AesGcmState(comptime key_len: usize) type {
            return struct {
                key: [key_len]u8,
                iv: [12]u8,

                const Self = @This();
                const AEAD = if (key_len == 16) crypto.aead.aes_gcm.Aes128Gcm else crypto.aead.aes_gcm.Aes256Gcm;

                pub fn init(key: []const u8, iv: []const u8) RecordError!Self {
                    if (key.len != key_len) return error.InvalidKeyLength;
                    if (iv.len != 12) return error.InvalidIvLength;

                    var self: Self = undefined;
                    @memcpy(self.key[0..], key);
                    @memcpy(self.iv[0..], iv);
                    return self;
                }

                pub fn encrypt(
                    self: *const Self,
                    ciphertext: []u8,
                    tag: *[16]u8,
                    plaintext: []const u8,
                    additional_data: []const u8,
                    seq_num: u64,
                ) void {
                    const nonce = self.computeNonce(seq_num);
                    AEAD.encrypt(ciphertext, tag, plaintext, additional_data, nonce, self.key);
                }

                pub fn decrypt(
                    self: *const Self,
                    plaintext: []u8,
                    ciphertext: []const u8,
                    tag: [16]u8,
                    additional_data: []const u8,
                    seq_num: u64,
                ) crypto.errors.AuthenticationError!void {
                    const nonce = self.computeNonce(seq_num);
                    try AEAD.decrypt(plaintext, ciphertext, tag, additional_data, nonce, self.key);
                }

                pub fn encryptTls12(
                    self: *const Self,
                    ciphertext: []u8,
                    tag: *[16]u8,
                    plaintext: []const u8,
                    additional_data: []const u8,
                    explicit_nonce: [8]u8,
                ) void {
                    var nonce: [12]u8 = undefined;
                    @memcpy(nonce[0..4], self.iv[0..4]);
                    @memcpy(nonce[4..12], explicit_nonce[0..8]);
                    AEAD.encrypt(ciphertext, tag, plaintext, additional_data, nonce, self.key);
                }

                pub fn decryptTls12(
                    self: *const Self,
                    plaintext: []u8,
                    ciphertext: []const u8,
                    tag: [16]u8,
                    additional_data: []const u8,
                    explicit_nonce: [8]u8,
                ) crypto.errors.AuthenticationError!void {
                    var nonce: [12]u8 = undefined;
                    @memcpy(nonce[0..4], self.iv[0..4]);
                    @memcpy(nonce[4..12], explicit_nonce[0..8]);
                    try AEAD.decrypt(plaintext, ciphertext, tag, additional_data, nonce, self.key);
                }

                pub fn tls12ExplicitNonceLength(_: *const Self) usize {
                    return 8;
                }

                fn computeNonce(self: *const Self, seq_num: u64) [12]u8 {
                    var nonce = self.iv;
                    var seq_bytes: [8]u8 = undefined;
                    mem.writeInt(u64, &seq_bytes, seq_num, .big);

                    for (0..8) |i| {
                        nonce[4 + i] ^= seq_bytes[i];
                    }
                    return nonce;
                }
            };
        }

        pub const ChaChaState = struct {
            key: [32]u8,
            iv: [12]u8,

            const Self = @This();
            const AEAD = crypto.aead.chacha_poly.ChaCha20Poly1305;

            pub fn init(key: []const u8, iv: []const u8) RecordError!Self {
                if (key.len != 32) return error.InvalidKeyLength;
                if (iv.len != 12) return error.InvalidIvLength;

                var self: Self = undefined;
                @memcpy(self.key[0..], key);
                @memcpy(self.iv[0..], iv);
                return self;
            }

            pub fn encrypt(
                self: *const Self,
                ciphertext: []u8,
                tag: *[16]u8,
                plaintext: []const u8,
                additional_data: []const u8,
                seq_num: u64,
            ) void {
                const nonce = self.computeNonce(seq_num);
                AEAD.encrypt(ciphertext, tag, plaintext, additional_data, nonce, self.key);
            }

            pub fn decrypt(
                self: *const Self,
                plaintext: []u8,
                ciphertext: []const u8,
                tag: [16]u8,
                additional_data: []const u8,
                seq_num: u64,
            ) crypto.errors.AuthenticationError!void {
                const nonce = self.computeNonce(seq_num);
                try AEAD.decrypt(plaintext, ciphertext, tag, additional_data, nonce, self.key);
            }

            pub fn encryptTls12(
                self: *const Self,
                ciphertext: []u8,
                tag: *[16]u8,
                plaintext: []const u8,
                additional_data: []const u8,
                explicit_nonce: [8]u8,
            ) void {
                var nonce = self.iv;
                for (0..8) |i| {
                    nonce[4 + i] ^= explicit_nonce[i];
                }
                AEAD.encrypt(ciphertext, tag, plaintext, additional_data, nonce, self.key);
            }

            pub fn decryptTls12(
                self: *const Self,
                plaintext: []u8,
                ciphertext: []const u8,
                tag: [16]u8,
                additional_data: []const u8,
                explicit_nonce: [8]u8,
            ) crypto.errors.AuthenticationError!void {
                var nonce = self.iv;
                for (0..8) |i| {
                    nonce[4 + i] ^= explicit_nonce[i];
                }
                try AEAD.decrypt(plaintext, ciphertext, tag, additional_data, nonce, self.key);
            }

            pub fn tls12ExplicitNonceLength(_: *const Self) usize {
                return 0;
            }

            fn computeNonce(self: *const Self, seq_num: u64) [12]u8 {
                var nonce = self.iv;
                var seq_bytes: [8]u8 = undefined;
                mem.writeInt(u64, &seq_bytes, seq_num, .big);

                for (0..8) |i| {
                    nonce[4 + i] ^= seq_bytes[i];
                }
                return nonce;
            }
        };

        pub fn RecordLayer(comptime ConnType: type) type {
            return struct {
                conn: ConnType,
                read_cipher: CipherState(),
                write_cipher: CipherState(),
                read_seq: u64,
                write_seq: u64,
                version: common.ProtocolVersion,

                const Self = @This();

                pub fn init(conn: ConnType) Self {
                    return .{
                        .conn = conn,
                        .read_cipher = .none,
                        .write_cipher = .none,
                        .read_seq = 0,
                        .write_seq = 0,
                        .version = .tls_1_2,
                    };
                }

                pub fn setVersion(self: *Self, version: common.ProtocolVersion) void {
                    self.version = version;
                }

                pub fn setReadCipher(self: *Self, cipher: CipherState()) void {
                    self.read_cipher = cipher;
                    self.read_seq = 0;
                }

                pub fn setWriteCipher(self: *Self, cipher: CipherState()) void {
                    self.write_cipher = cipher;
                    self.write_seq = 0;
                }

                pub fn writeRecord(
                    self: *Self,
                    content_type: common.ContentType,
                    plaintext: []const u8,
                    buffer: []u8,
                    plaintext_scratch: []u8,
                ) RecordError!usize {
                    if (plaintext.len > common.MAX_PLAINTEXT_LEN) return error.RecordTooLarge;

                    return switch (self.write_cipher) {
                        .none => try self.writePlainRecord(content_type, plaintext, buffer),
                        inline .aes_128_gcm, .aes_256_gcm, .chacha20_poly1305 => |cipher| blk: {
                            if (self.version == .tls_1_3) {
                                break :blk try self.writeEncryptedTls13(content_type, plaintext, cipher, buffer, plaintext_scratch);
                            } else {
                                break :blk try self.writeEncryptedTls12(content_type, plaintext, cipher, buffer);
                            }
                        },
                    };
                }

                pub fn readRecord(self: *Self, buffer: []u8, plaintext_out: []u8) RecordError!ReadRecordResult {
                    var header_buf: [common.RecordHeader.SIZE]u8 = undefined;
                    try self.connReadAll(&header_buf);

                    const header = common.RecordHeader.parse(&header_buf) catch return error.UnexpectedRecord;
                    const max_record_len: usize = if (self.version == .tls_1_2)
                        common.MAX_CIPHERTEXT_LEN_TLS12
                    else
                        common.MAX_CIPHERTEXT_LEN;

                    if (header.length > max_record_len) return error.RecordTooLarge;
                    if (buffer.len < header.length) return error.BufferTooSmall;

                    const record_body = buffer[0..header.length];
                    try self.connReadAll(record_body);

                    if (header.content_type == .change_cipher_spec) {
                        if (plaintext_out.len < header.length) return error.BufferTooSmall;
                        @memcpy(plaintext_out[0..header.length], record_body);
                        return .{ .content_type = header.content_type, .length = header.length };
                    }

                    return switch (self.read_cipher) {
                        .none => blk: {
                            if (plaintext_out.len < header.length) return error.BufferTooSmall;
                            @memcpy(plaintext_out[0..header.length], record_body);
                            break :blk .{ .content_type = header.content_type, .length = header.length };
                        },
                        inline .aes_128_gcm, .aes_256_gcm, .chacha20_poly1305 => |cipher| blk: {
                            if (self.version == .tls_1_3) {
                                break :blk try self.readEncryptedTls13(header_buf, header, record_body, plaintext_out, cipher);
                            } else {
                                break :blk try self.readEncryptedTls12(header, record_body, plaintext_out, cipher);
                            }
                        },
                    };
                }

                pub fn sendAlert(
                    self: *Self,
                    level: common.AlertLevel,
                    description: common.AlertDescription,
                    buffer: []u8,
                    plaintext_scratch: []u8,
                ) RecordError!void {
                    const payload = [_]u8{ @intFromEnum(level), @intFromEnum(description) };
                    _ = try self.writeRecord(.alert, &payload, buffer, plaintext_scratch);
                }

                fn writePlainRecord(
                    self: *Self,
                    content_type: common.ContentType,
                    plaintext: []const u8,
                    buffer: []u8,
                ) RecordError!usize {
                    const total_len = common.RecordHeader.SIZE + plaintext.len;
                    if (buffer.len < total_len) return error.BufferTooSmall;

                    const header: common.RecordHeader = .{
                        .content_type = content_type,
                        .legacy_version = self.version,
                        .length = @intCast(plaintext.len),
                    };
                    try header.serialize(buffer[0..common.RecordHeader.SIZE]);
                    @memcpy(buffer[common.RecordHeader.SIZE..][0..plaintext.len], plaintext);

                    self.connWriteAll(buffer[0..total_len]) catch |err| return err;
                    return total_len;
                }

                fn writeEncryptedTls13(
                    self: *Self,
                    content_type: common.ContentType,
                    plaintext: []const u8,
                    cipher: anytype,
                    buffer: []u8,
                    plaintext_scratch: []u8,
                ) RecordError!usize {
                    const inner_len = plaintext.len + 1;
                    const ciphertext_len = inner_len + 16;
                    const total_len = common.RecordHeader.SIZE + ciphertext_len;
                    if (buffer.len < total_len) return error.BufferTooSmall;
                    if (plaintext_scratch.len < inner_len) return error.BufferTooSmall;

                    const header: common.RecordHeader = .{
                        .content_type = .application_data,
                        .legacy_version = .tls_1_2,
                        .length = @intCast(ciphertext_len),
                    };
                    try header.serialize(buffer[0..common.RecordHeader.SIZE]);

                    const inner_plaintext = plaintext_scratch[0..inner_len];
                    if (@intFromPtr(inner_plaintext.ptr) != @intFromPtr(plaintext.ptr)) {
                        @memcpy(inner_plaintext[0..plaintext.len], plaintext);
                    }
                    inner_plaintext[plaintext.len] = @intFromEnum(content_type);

                    var tag: [16]u8 = undefined;
                    cipher.encrypt(
                        buffer[common.RecordHeader.SIZE..][0..inner_len],
                        &tag,
                        inner_plaintext,
                        buffer[0..common.RecordHeader.SIZE],
                        self.write_seq,
                    );
                    @memcpy(buffer[common.RecordHeader.SIZE + inner_len ..][0..16], &tag);

                    self.write_seq += 1;
                    self.connWriteAll(buffer[0..total_len]) catch |err| return err;
                    return total_len;
                }

                fn writeEncryptedTls12(
                    self: *Self,
                    content_type: common.ContentType,
                    plaintext: []const u8,
                    cipher: anytype,
                    buffer: []u8,
                ) RecordError!usize {
                    const explicit_nonce_len = cipher.tls12ExplicitNonceLength();
                    const record_len = explicit_nonce_len + plaintext.len + 16;
                    const total_len = common.RecordHeader.SIZE + record_len;
                    if (buffer.len < total_len) return error.BufferTooSmall;

                    const header: common.RecordHeader = .{
                        .content_type = content_type,
                        .legacy_version = self.version,
                        .length = @intCast(record_len),
                    };
                    try header.serialize(buffer[0..common.RecordHeader.SIZE]);

                    var explicit_nonce: [8]u8 = undefined;
                    mem.writeInt(u64, &explicit_nonce, self.write_seq, .big);
                    if (explicit_nonce_len != 0) {
                        @memcpy(buffer[common.RecordHeader.SIZE..][0..explicit_nonce_len], explicit_nonce[0..explicit_nonce_len]);
                    }

                    var ad = self.additionalData(self.write_seq, content_type, self.version, plaintext.len);

                    var tag: [16]u8 = undefined;
                    cipher.encryptTls12(
                        buffer[common.RecordHeader.SIZE + explicit_nonce_len ..][0..plaintext.len],
                        &tag,
                        plaintext,
                        &ad,
                        explicit_nonce,
                    );
                    @memcpy(buffer[common.RecordHeader.SIZE + explicit_nonce_len + plaintext.len ..][0..16], &tag);

                    self.write_seq += 1;
                    self.connWriteAll(buffer[0..total_len]) catch |err| return err;
                    return total_len;
                }

                fn readEncryptedTls13(
                    self: *Self,
                    header_buf: [common.RecordHeader.SIZE]u8,
                    header: common.RecordHeader,
                    record_body: []const u8,
                    plaintext_out: []u8,
                    cipher: anytype,
                ) RecordError!ReadRecordResult {
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
                    const inner_content_type: common.ContentType = @enumFromInt(plaintext_out[inner_len]);
                    switch (inner_content_type) {
                        .alert, .handshake, .application_data => {},
                        else => return error.UnexpectedRecord,
                    }
                    return .{ .content_type = inner_content_type, .length = inner_len };
                }

                fn readEncryptedTls12(
                    self: *Self,
                    header: common.RecordHeader,
                    record_body: []const u8,
                    plaintext_out: []u8,
                    cipher: anytype,
                ) RecordError!ReadRecordResult {
                    const explicit_nonce_len = cipher.tls12ExplicitNonceLength();
                    if (header.length < explicit_nonce_len + 16 + 1) return error.BadRecordMac;

                    var explicit_nonce: [8]u8 = undefined;
                    if (explicit_nonce_len == 0) {
                        mem.writeInt(u64, &explicit_nonce, self.read_seq, .big);
                    } else {
                        explicit_nonce = record_body[0..8].*;
                    }
                    const ciphertext_len = header.length - explicit_nonce_len - 16;
                    const ciphertext = record_body[explicit_nonce_len..][0..ciphertext_len];
                    const tag = record_body[explicit_nonce_len + ciphertext_len ..][0..16].*;
                    if (plaintext_out.len < ciphertext_len) return error.BufferTooSmall;

                    var ad = self.additionalData(self.read_seq, header.content_type, header.legacy_version, ciphertext_len);

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

                fn additionalData(
                    self: *const Self,
                    seq_num: u64,
                    content_type: common.ContentType,
                    version: common.ProtocolVersion,
                    plaintext_len: usize,
                ) [13]u8 {
                    _ = self;

                    var out: [13]u8 = undefined;
                    mem.writeInt(u64, out[0..8], seq_num, .big);
                    out[8] = @intFromEnum(content_type);
                    mem.writeInt(u16, out[9..11], @intFromEnum(version), .big);
                    mem.writeInt(u16, out[11..13], @intCast(plaintext_len), .big);
                    return out;
                }

                fn connReadAll(self: *Self, buf: []u8) RecordError!void {
                    var filled: usize = 0;
                    while (filled < buf.len) {
                        const n = self.conn.read(buf[filled..]) catch |err| return mapConnReadError(err);
                        if (n == 0) return error.UnexpectedRecord;
                        filled += n;
                    }
                }

                fn mapConnReadError(err: anyerror) RecordError {
                    if (errorNameEquals(err, "TimedOut")) return error.TimedOut;
                    if (errorNameEquals(err, "ConnectionRefused")) return error.ConnectionRefused;
                    if (errorNameEquals(err, "ConnectionReset")) return error.ConnectionReset;
                    if (errorNameEquals(err, "BrokenPipe")) return error.BrokenPipe;
                    return error.UnexpectedRecord;
                }

                fn connWriteAll(self: *Self, buf: []const u8) RecordError!void {
                    var written: usize = 0;
                    while (written < buf.len) {
                        const n = self.conn.write(buf[written..]) catch |err| return mapConnWriteError(err);
                        if (n == 0) return error.UnexpectedRecord;
                        written += n;
                    }
                }

                fn mapConnWriteError(err: anyerror) RecordError {
                    if (errorNameEquals(err, "TimedOut")) return error.TimedOut;
                    if (errorNameEquals(err, "ConnectionRefused")) return error.ConnectionRefused;
                    if (errorNameEquals(err, "ConnectionReset")) return error.ConnectionReset;
                    if (errorNameEquals(err, "BrokenPipe")) return error.BrokenPipe;
                    return error.UnexpectedRecord;
                }

                fn errorNameEquals(err: anyerror, comptime expected: []const u8) bool {
                    const name = @errorName(err);
                    if (name.len != expected.len) return false;
                    inline for (expected, 0..) |byte, i| {
                        if (name[i] != byte) return false;
                    }
                    return true;
                }
            };
        }
    };
}

pub fn TestRunner(comptime std: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(std, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: std.mem.Allocator) !void {
            _ = allocator;
            const testing = std.testing;
            const common = @import("common.zig").make(std);
            const record = make(std);

            {
                const key16 = [_]u8{0x01} ** 16;
                const key32 = [_]u8{0x02} ** 32;
                const iv = [_]u8{0x03} ** 12;
                const plaintext = "hello record";
                const ad = "aad";

                var aes128 = try record.AesGcmState(16).init(&key16, &iv);
                var aes128_ct: [plaintext.len]u8 = undefined;
                var aes128_tag: [16]u8 = undefined;
                aes128.encrypt(&aes128_ct, &aes128_tag, plaintext, ad, 1);
                var aes128_pt: [plaintext.len]u8 = undefined;
                try aes128.decrypt(&aes128_pt, &aes128_ct, aes128_tag, ad, 1);
                try testing.expectEqualSlices(u8, plaintext, &aes128_pt);

                var chacha = try record.ChaChaState.init(&key32, &iv);
                var chacha_ct: [plaintext.len]u8 = undefined;
                var chacha_tag: [16]u8 = undefined;
                chacha.encrypt(&chacha_ct, &chacha_tag, plaintext, ad, 2);
                var chacha_pt: [plaintext.len]u8 = undefined;
                try chacha.decrypt(&chacha_pt, &chacha_ct, chacha_tag, ad, 2);
                try testing.expectEqualSlices(u8, plaintext, &chacha_pt);
            }

            {
                const MockConn = struct {
                    read_buf: [512]u8 = undefined,
                    read_len: usize = 0,
                    read_pos: usize = 0,
                    write_buf: [512]u8 = undefined,
                    write_len: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        if (self.read_pos >= self.read_len) return error.EndOfStream;
                        const n = @min(buf.len, self.read_len - self.read_pos);
                        @memcpy(buf[0..n], self.read_buf[self.read_pos..][0..n]);
                        self.read_pos += n;
                        return n;
                    }

                    pub fn write(self: *@This(), buf: []const u8) error{ ConnectionReset, BrokenPipe, TimedOut, Unexpected }!usize {
                        const n = @min(buf.len, self.write_buf.len - self.write_len);
                        if (n == 0) return error.Unexpected;
                        @memcpy(self.write_buf[self.write_len..][0..n], buf[0..n]);
                        self.write_len += n;
                        return n;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                    pub fn setWriteDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                };

                var mock = MockConn{};
                var layer = record.RecordLayer(*MockConn).init(&mock);

                var write_buf: [128]u8 = undefined;
                var plaintext_buf: [128]u8 = undefined;
                _ = try layer.writeRecord(.handshake, "abc", &write_buf, &plaintext_buf);

                @memcpy(mock.read_buf[0..mock.write_len], mock.write_buf[0..mock.write_len]);
                mock.read_len = mock.write_len;
                mock.read_pos = 0;

                var cipher_buf: [128]u8 = undefined;
                var plaintext_out: [128]u8 = undefined;
                const result = try layer.readRecord(&cipher_buf, &plaintext_out);
                try testing.expectEqual(common.ContentType.handshake, result.content_type);
                try testing.expectEqual(@as(usize, 3), result.length);
                try testing.expectEqualSlices(u8, "abc", plaintext_out[0..result.length]);
            }

            {
                const MockConn = struct {
                    read_buf: [1024]u8 = undefined,
                    read_len: usize = 0,
                    read_pos: usize = 0,
                    write_buf: [1024]u8 = undefined,
                    write_len: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        if (self.read_pos >= self.read_len) return error.EndOfStream;
                        const n = @min(buf.len, self.read_len - self.read_pos);
                        @memcpy(buf[0..n], self.read_buf[self.read_pos..][0..n]);
                        self.read_pos += n;
                        return n;
                    }

                    pub fn write(self: *@This(), buf: []const u8) error{ ConnectionReset, BrokenPipe, TimedOut, Unexpected }!usize {
                        const n = @min(buf.len, self.write_buf.len - self.write_len);
                        if (n == 0) return error.Unexpected;
                        @memcpy(self.write_buf[self.write_len..][0..n], buf[0..n]);
                        self.write_len += n;
                        return n;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                    pub fn setWriteDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                };

                const key = [_]u8{0x11} ** 16;
                const iv = [_]u8{0x22} ** 12;

                var writer_conn = MockConn{};
                var writer = record.RecordLayer(*MockConn).init(&writer_conn);
                writer.setVersion(.tls_1_3);
                writer.setWriteCipher(try record.CipherState().init(.TLS_AES_128_GCM_SHA256, &key, &iv));

                var wire_buf: [512]u8 = undefined;
                var plaintext_buf: [common.MAX_PLAINTEXT_LEN + 1]u8 = undefined;
                _ = try writer.writeRecord(.handshake, "hello", &wire_buf, &plaintext_buf);

                var reader_conn = MockConn{};
                @memcpy(reader_conn.read_buf[0..writer_conn.write_len], writer_conn.write_buf[0..writer_conn.write_len]);
                reader_conn.read_len = writer_conn.write_len;

                var reader = record.RecordLayer(*MockConn).init(&reader_conn);
                reader.setVersion(.tls_1_3);
                reader.setReadCipher(try record.CipherState().init(.TLS_AES_128_GCM_SHA256, &key, &iv));

                var cipher_buf: [512]u8 = undefined;
                var plaintext_out: [512]u8 = undefined;
                const result = try reader.readRecord(&cipher_buf, &plaintext_out);
                try testing.expectEqual(common.ContentType.handshake, result.content_type);
                try testing.expectEqual(@as(usize, 5), result.length);
                try testing.expectEqualSlices(u8, "hello", plaintext_out[0..result.length]);
            }

            {
                const MockConn = struct {
                    read_buf: [1024]u8 = undefined,
                    read_len: usize = 0,
                    read_pos: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        if (self.read_pos >= self.read_len) return error.EndOfStream;
                        const n = @min(buf.len, self.read_len - self.read_pos);
                        @memcpy(buf[0..n], self.read_buf[self.read_pos..][0..n]);
                        self.read_pos += n;
                        return n;
                    }

                    pub fn write(_: *@This(), _: []const u8) error{ ConnectionReset, BrokenPipe, TimedOut, Unexpected }!usize {
                        return error.Unexpected;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                    pub fn setWriteDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                };

                const key = [_]u8{0x11} ** 16;
                const iv = [_]u8{0x22} ** 12;

                const cipher = try record.CipherState().init(.TLS_AES_128_GCM_SHA256, &key, &iv);
                var mock = MockConn{};

                const plaintext = "hello";
                const inner_len = plaintext.len + 1;
                const header = common.RecordHeader{
                    .content_type = .application_data,
                    .legacy_version = .tls_1_2,
                    .length = @intCast(inner_len + 16),
                };
                try header.serialize(mock.read_buf[0..common.RecordHeader.SIZE]);

                var inner_plaintext: [plaintext.len + 1]u8 = undefined;
                @memcpy(inner_plaintext[0..plaintext.len], plaintext);
                inner_plaintext[plaintext.len] = @intFromEnum(common.ContentType.change_cipher_spec);

                var tag: [16]u8 = undefined;
                switch (cipher) {
                    .aes_128_gcm => |state| state.encrypt(
                        mock.read_buf[common.RecordHeader.SIZE..][0..inner_len],
                        &tag,
                        &inner_plaintext,
                        mock.read_buf[0..common.RecordHeader.SIZE],
                        0,
                    ),
                    else => unreachable,
                }
                @memcpy(mock.read_buf[common.RecordHeader.SIZE + inner_len ..][0..16], &tag);
                mock.read_len = common.RecordHeader.SIZE + inner_len + 16;

                var layer = record.RecordLayer(*MockConn).init(&mock);
                layer.setVersion(.tls_1_3);
                layer.setReadCipher(try record.CipherState().init(.TLS_AES_128_GCM_SHA256, &key, &iv));

                var cipher_buf: [512]u8 = undefined;
                var plaintext_out: [512]u8 = undefined;
                try testing.expectError(error.UnexpectedRecord, layer.readRecord(&cipher_buf, &plaintext_out));
            }

            {
                const MockConn = struct {
                    read_buf: [1024]u8 = undefined,
                    read_len: usize = 0,
                    read_pos: usize = 0,
                    write_buf: [1024]u8 = undefined,
                    write_len: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        if (self.read_pos >= self.read_len) return error.EndOfStream;
                        const n = @min(buf.len, self.read_len - self.read_pos);
                        @memcpy(buf[0..n], self.read_buf[self.read_pos..][0..n]);
                        self.read_pos += n;
                        return n;
                    }

                    pub fn write(self: *@This(), buf: []const u8) error{ ConnectionReset, BrokenPipe, TimedOut, Unexpected }!usize {
                        const n = @min(buf.len, self.write_buf.len - self.write_len);
                        if (n == 0) return error.Unexpected;
                        @memcpy(self.write_buf[self.write_len..][0..n], buf[0..n]);
                        self.write_len += n;
                        return n;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                    pub fn setWriteDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                };

                const key = [_]u8{0x33} ** 32;
                const iv = [_]u8{0x44} ** 12;

                var writer_conn = MockConn{};
                var writer = record.RecordLayer(*MockConn).init(&writer_conn);
                writer.setVersion(.tls_1_2);
                writer.setWriteCipher(try record.CipherState().init(.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256, &key, &iv));

                var wire_buf: [512]u8 = undefined;
                var plaintext_buf: [common.MAX_PLAINTEXT_LEN + 1]u8 = undefined;
                _ = try writer.writeRecord(.application_data, "hello", &wire_buf, &plaintext_buf);

                const header = try common.RecordHeader.parse(writer_conn.write_buf[0..common.RecordHeader.SIZE]);
                try testing.expectEqual(@as(u16, "hello".len + 16), header.length);

                var reader_conn = MockConn{};
                @memcpy(reader_conn.read_buf[0..writer_conn.write_len], writer_conn.write_buf[0..writer_conn.write_len]);
                reader_conn.read_len = writer_conn.write_len;

                var reader = record.RecordLayer(*MockConn).init(&reader_conn);
                reader.setVersion(.tls_1_2);
                reader.setReadCipher(try record.CipherState().init(.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256, &key, &iv));

                var cipher_buf: [512]u8 = undefined;
                var plaintext_out: [512]u8 = undefined;
                const result = try reader.readRecord(&cipher_buf, &plaintext_out);
                try testing.expectEqual(common.ContentType.application_data, result.content_type);
                try testing.expectEqual(@as(usize, 5), result.length);
                try testing.expectEqualSlices(u8, "hello", plaintext_out[0..result.length]);
            }

            {
                const MockConn = struct {
                    step: u8 = 0,

                    pub fn read(self: *@This(), buf: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        switch (self.step) {
                            0 => {
                                self.step = 1;
                                buf[0] = 0x16;
                                buf[1] = 0x03;
                                return 2;
                            },
                            1 => return error.TimedOut,
                            else => return error.EndOfStream,
                        }
                    }

                    pub fn write(_: *@This(), _: []const u8) error{ ConnectionReset, BrokenPipe, TimedOut, Unexpected }!usize {
                        return error.Unexpected;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                    pub fn setWriteDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                };

                var mock = MockConn{};
                var layer = record.RecordLayer(*MockConn).init(&mock);
                var cipher_buf: [128]u8 = undefined;
                var plaintext_out: [128]u8 = undefined;

                try testing.expectError(error.TimedOut, layer.readRecord(&cipher_buf, &plaintext_out));
            }

            {
                const Helper = struct {
                    fn expectWriteError(comptime expected: anyerror) !void {
                        const MockConn = struct {
                            pub fn read(_: *@This(), _: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                                return error.EndOfStream;
                            }

                            pub fn write(_: *@This(), _: []const u8) error{ ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                                return expected;
                            }

                            pub fn close(_: *@This()) void {}
                            pub fn deinit(_: *@This()) void {}
                            pub fn setReadDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                            pub fn setWriteDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                        };

                        var mock = MockConn{};
                        var layer = record.RecordLayer(*MockConn).init(&mock);
                        var write_buf: [128]u8 = undefined;
                        var plaintext_buf: [128]u8 = undefined;
                        try testing.expectError(expected, layer.writeRecord(.application_data, "abc", &write_buf, &plaintext_buf));
                    }
                };

                inline for (.{ error.ConnectionRefused, error.ConnectionReset, error.BrokenPipe, error.TimedOut }) |expected| {
                    try Helper.expectWriteError(expected);
                }
            }

            {
                const Helper = struct {
                    const FailStage = enum {
                        header,
                        body,
                    };

                    fn expectReadError(comptime fail_stage: FailStage, comptime expected: anyerror) !void {
                        const MockConn = struct {
                            step: u8 = 0,

                            pub fn read(self: *@This(), buf: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                                switch (fail_stage) {
                                    .header => return expected,
                                    .body => switch (self.step) {
                                        0 => {
                                            self.step = 1;
                                            const header = [_]u8{
                                                @intFromEnum(common.ContentType.handshake),
                                                0x03,
                                                0x03,
                                                0x00,
                                                0x03,
                                            };
                                            @memcpy(buf[0..header.len], &header);
                                            return header.len;
                                        },
                                        1 => return expected,
                                        else => return error.EndOfStream,
                                    },
                                }
                            }

                            pub fn write(_: *@This(), _: []const u8) error{ ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                                return error.Unexpected;
                            }

                            pub fn close(_: *@This()) void {}
                            pub fn deinit(_: *@This()) void {}
                            pub fn setReadDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                            pub fn setWriteDeadline(_: *@This(), _: ?time_mod.instant.Time) void {}
                        };

                        var mock = MockConn{};
                        var layer = record.RecordLayer(*MockConn).init(&mock);
                        var cipher_buf: [128]u8 = undefined;
                        var plaintext_out: [128]u8 = undefined;
                        try testing.expectError(expected, layer.readRecord(&cipher_buf, &plaintext_out));
                    }
                };

                inline for (.{ error.ConnectionRefused, error.ConnectionReset, error.BrokenPipe, error.TimedOut }) |expected| {
                    try Helper.expectReadError(.header, expected);
                    try Helper.expectReadError(.body, expected);
                }
            }
        }
    }.run);
}
