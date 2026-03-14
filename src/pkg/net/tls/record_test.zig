const std = @import("std");
const testing = std.testing;
const module = @import("record.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const RecordHeader = module.RecordHeader;
const CipherState = module.CipherState;
const RecordError = module.RecordError;
const RecordLayer = module.RecordLayer;
const runtime = test_exports.runtime;
const common = test_exports.common;
const ContentType = test_exports.ContentType;
const ProtocolVersion = test_exports.ProtocolVersion;
const CipherSuite = test_exports.CipherSuite;
const AlertDescription = test_exports.AlertDescription;
const AlertLevel = test_exports.AlertLevel;
const AesGcmState = test_exports.AesGcmState;
const ChaChaState = test_exports.ChaChaState;
const MockConn = test_exports.MockConn;

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
