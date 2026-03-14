const std = @import("std");
const testing = std.testing;
const module = @import("common.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const ProtocolVersion = module.ProtocolVersion;
const ContentType = module.ContentType;
const HandshakeType = module.HandshakeType;
const CipherSuite = module.CipherSuite;
const NamedGroup = module.NamedGroup;
const SignatureScheme = module.SignatureScheme;
const ExtensionType = module.ExtensionType;
const AlertLevel = module.AlertLevel;
const AlertDescription = module.AlertDescription;
const Alert = module.Alert;
const MAX_PLAINTEXT_LEN = module.MAX_PLAINTEXT_LEN;
const MAX_CIPHERTEXT_LEN = module.MAX_CIPHERTEXT_LEN;
const MAX_CIPHERTEXT_LEN_TLS12 = module.MAX_CIPHERTEXT_LEN_TLS12;
const RECORD_HEADER_LEN = module.RECORD_HEADER_LEN;
const MAX_HANDSHAKE_LEN = module.MAX_HANDSHAKE_LEN;
const ChangeCipherSpecType = module.ChangeCipherSpecType;
const CompressionMethod = module.CompressionMethod;
const PskKeyExchangeMode = module.PskKeyExchangeMode;

test "CipherSuite properties" {
    const suite = CipherSuite.TLS_AES_128_GCM_SHA256;
    try std.testing.expect(suite.isTls13());
    try std.testing.expectEqual(@as(u8, 16), suite.keyLength());
    try std.testing.expectEqual(@as(u8, 12), suite.ivLength());
}

test "ProtocolVersion names" {
    try std.testing.expectEqualStrings("TLS 1.3", ProtocolVersion.tls_1_3.name());
    try std.testing.expectEqualStrings("TLS 1.2", ProtocolVersion.tls_1_2.name());
    try std.testing.expectEqualStrings("TLS 1.1", ProtocolVersion.tls_1_1.name());
    try std.testing.expectEqualStrings("TLS 1.0", ProtocolVersion.tls_1_0.name());
}

test "CipherSuite TLS 1.3 suites" {
    const tls13_suites = [_]CipherSuite{
        .TLS_AES_128_GCM_SHA256,
        .TLS_AES_256_GCM_SHA384,
        .TLS_CHACHA20_POLY1305_SHA256,
    };
    for (tls13_suites) |s| {
        try std.testing.expect(s.isTls13());
    }
}

test "CipherSuite TLS 1.2 suites are not TLS 1.3" {
    const tls12_suites = [_]CipherSuite{
        .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
        .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
        .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
        .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
        .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
        .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
    };
    for (tls12_suites) |s| {
        try std.testing.expect(!s.isTls13());
    }
}

test "CipherSuite key/iv/tag lengths for all suites" {
    const Suite = struct { suite: CipherSuite, key: u8, iv: u8 };
    const cases = [_]Suite{
        .{ .suite = .TLS_AES_128_GCM_SHA256, .key = 16, .iv = 12 },
        .{ .suite = .TLS_AES_256_GCM_SHA384, .key = 32, .iv = 12 },
        .{ .suite = .TLS_CHACHA20_POLY1305_SHA256, .key = 32, .iv = 12 },
        .{ .suite = .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, .key = 16, .iv = 12 },
        .{ .suite = .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384, .key = 32, .iv = 12 },
        .{ .suite = .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256, .key = 32, .iv = 12 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.key, c.suite.keyLength());
        try std.testing.expectEqual(c.iv, c.suite.ivLength());
        try std.testing.expectEqual(@as(u8, 16), c.suite.tagLength());
    }
}

test "CipherSuite unknown suite returns zero lengths" {
    const unknown: CipherSuite = @enumFromInt(0xFFFF);
    try std.testing.expect(!unknown.isTls13());
    try std.testing.expectEqual(@as(u8, 0), unknown.keyLength());
    try std.testing.expectEqual(@as(u8, 0), unknown.ivLength());
}

test "ProtocolVersion enum values" {
    try std.testing.expectEqual(@as(u16, 0x0301), @intFromEnum(ProtocolVersion.tls_1_0));
    try std.testing.expectEqual(@as(u16, 0x0302), @intFromEnum(ProtocolVersion.tls_1_1));
    try std.testing.expectEqual(@as(u16, 0x0303), @intFromEnum(ProtocolVersion.tls_1_2));
    try std.testing.expectEqual(@as(u16, 0x0304), @intFromEnum(ProtocolVersion.tls_1_3));
}

test "ContentType enum values" {
    try std.testing.expectEqual(@as(u8, 20), @intFromEnum(ContentType.change_cipher_spec));
    try std.testing.expectEqual(@as(u8, 21), @intFromEnum(ContentType.alert));
    try std.testing.expectEqual(@as(u8, 22), @intFromEnum(ContentType.handshake));
    try std.testing.expectEqual(@as(u8, 23), @intFromEnum(ContentType.application_data));
}

test "MAX_PLAINTEXT_LEN and MAX_CIPHERTEXT_LEN" {
    try std.testing.expectEqual(@as(usize, 16384), MAX_PLAINTEXT_LEN);
    try std.testing.expect(MAX_CIPHERTEXT_LEN > MAX_PLAINTEXT_LEN);
    try std.testing.expectEqual(@as(usize, 5), RECORD_HEADER_LEN);
}

test "AlertLevel and AlertDescription values" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(AlertLevel.warning));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(AlertLevel.fatal));
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(AlertDescription.close_notify));
    try std.testing.expectEqual(@as(u8, 40), @intFromEnum(AlertDescription.handshake_failure));
}

test "NamedGroup enum values" {
    try std.testing.expectEqual(@as(u16, 29), @intFromEnum(NamedGroup.x25519));
    try std.testing.expectEqual(@as(u16, 23), @intFromEnum(NamedGroup.secp256r1));
}

test "SignatureScheme enum values" {
    try std.testing.expectEqual(@as(u16, 0x0403), @intFromEnum(SignatureScheme.ecdsa_secp256r1_sha256));
    try std.testing.expectEqual(@as(u16, 0x0804), @intFromEnum(SignatureScheme.rsa_pss_rsae_sha256));
}

test "ExtensionType enum values" {
    try std.testing.expectEqual(@as(u16, 0), @intFromEnum(ExtensionType.server_name));
    try std.testing.expectEqual(@as(u16, 43), @intFromEnum(ExtensionType.supported_versions));
    try std.testing.expectEqual(@as(u16, 51), @intFromEnum(ExtensionType.key_share));
}
