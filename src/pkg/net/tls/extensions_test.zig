const std = @import("std");
const testing = std.testing;
const module = @import("extensions.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const ExtensionError = module.ExtensionError;
const ExtensionBuilder = module.ExtensionBuilder;
const KeyShareEntry = module.KeyShareEntry;
const Extension = module.Extension;
const parseExtensions = module.parseExtensions;
const parseServerName = module.parseServerName;
const parseSupportedVersion = module.parseSupportedVersion;
const parseKeyShareServer = module.parseKeyShareServer;
const common = test_exports.common;
const ExtensionType = test_exports.ExtensionType;
const NamedGroup = test_exports.NamedGroup;
const SignatureScheme = test_exports.SignatureScheme;
const ProtocolVersion = test_exports.ProtocolVersion;
const CipherSuite = test_exports.CipherSuite;
const PskKeyExchangeMode = test_exports.PskKeyExchangeMode;

test "ExtensionBuilder server name" {
    var buf: [256]u8 = undefined;
    var builder = ExtensionBuilder.init(&buf);

    try builder.addServerName("example.com");

    const data = builder.getData();
    try std.testing.expect(data.len > 0);

    const ext_type = std.mem.readInt(u16, data[0..2], .big);
    try std.testing.expectEqual(@as(u16, 0), ext_type);
}

test "ExtensionBuilder supported versions" {
    var buf: [256]u8 = undefined;
    var builder = ExtensionBuilder.init(&buf);

    const versions = [_]ProtocolVersion{ .tls_1_3, .tls_1_2 };
    try builder.addSupportedVersions(&versions);

    const data = builder.getData();
    try std.testing.expect(data.len > 0);
}

test "parseServerName" {
    var buf: [256]u8 = undefined;
    var builder = ExtensionBuilder.init(&buf);
    try builder.addServerName("test.example.com");

    const ext_data = builder.getData()[4..];
    const hostname = try parseServerName(ext_data);
    try std.testing.expectEqualStrings("test.example.com", hostname.?);
}

test "ExtensionBuilder buffer overflow" {
    var buf: [4]u8 = undefined;
    var builder = ExtensionBuilder.init(&buf);
    try std.testing.expectError(error.BufferTooSmall, builder.addServerName("this-hostname-is-way-too-long-for-a-4-byte-buffer.example.com"));
}

test "ExtensionBuilder addSupportedGroups" {
    var buf: [256]u8 = undefined;
    var builder = ExtensionBuilder.init(&buf);

    const groups = [_]NamedGroup{ .x25519, .secp256r1 };
    try builder.addSupportedGroups(&groups);

    const data = builder.getData();
    try std.testing.expect(data.len > 0);

    const ext_type = std.mem.readInt(u16, data[0..2], .big);
    try std.testing.expectEqual(@as(u16, @intFromEnum(ExtensionType.supported_groups)), ext_type);
}

test "ExtensionBuilder addSignatureAlgorithms" {
    var buf: [256]u8 = undefined;
    var builder = ExtensionBuilder.init(&buf);

    const sig_algs = [_]SignatureScheme{
        .ecdsa_secp256r1_sha256,
        .rsa_pss_rsae_sha256,
    };
    try builder.addSignatureAlgorithms(&sig_algs);

    const data = builder.getData();
    try std.testing.expect(data.len > 0);

    const ext_type = std.mem.readInt(u16, data[0..2], .big);
    try std.testing.expectEqual(@as(u16, @intFromEnum(ExtensionType.signature_algorithms)), ext_type);
}

test "parseSupportedVersion" {
    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, @intFromEnum(ProtocolVersion.tls_1_3), .big);
    const version = try parseSupportedVersion(&data);
    try std.testing.expectEqual(ProtocolVersion.tls_1_3, version);
}

test "parseSupportedVersion too small" {
    const data: [1]u8 = .{0};
    try std.testing.expectError(error.InvalidExtension, parseSupportedVersion(&data));
}

test "parseKeyShareServer" {
    var data: [36]u8 = undefined;
    std.mem.writeInt(u16, data[0..2], @intFromEnum(NamedGroup.x25519), .big);
    std.mem.writeInt(u16, data[2..4], 32, .big);
    @memset(data[4..36], 0xAA);

    const entry = try parseKeyShareServer(&data);
    try std.testing.expectEqual(NamedGroup.x25519, entry.group);
    try std.testing.expectEqual(@as(usize, 32), entry.key_exchange.len);
}

test "parseKeyShareServer too small header" {
    const data: [3]u8 = .{ 0, 0, 0 };
    try std.testing.expectError(error.InvalidExtension, parseKeyShareServer(&data));
}

test "parseKeyShareServer truncated key data" {
    var data: [6]u8 = undefined;
    std.mem.writeInt(u16, data[0..2], @intFromEnum(NamedGroup.x25519), .big);
    std.mem.writeInt(u16, data[2..4], 32, .big);
    try std.testing.expectError(error.InvalidExtension, parseKeyShareServer(&data));
}

test "ExtensionBuilder multiple extensions" {
    var buf: [512]u8 = undefined;
    var builder = ExtensionBuilder.init(&buf);

    try builder.addServerName("example.com");
    const after_sni = builder.getData().len;

    const versions = [_]ProtocolVersion{ .tls_1_3, .tls_1_2 };
    try builder.addSupportedVersions(&versions);
    const after_versions = builder.getData().len;

    try std.testing.expect(after_versions > after_sni);
}

test "parseServerName too short data" {
    const data: [2]u8 = .{ 0, 0 };
    try std.testing.expectError(error.InvalidExtension, parseServerName(&data));
}

test "parseServerName empty list" {
    var data: [5]u8 = undefined;
    std.mem.writeInt(u16, data[0..2], 3, .big);
    data[2] = 0;
    std.mem.writeInt(u16, data[3..5], 0, .big);
    const result = try parseServerName(&data);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.len);
}

test "ExtensionBuilder addPskKeyExchangeModes" {
    var buf: [256]u8 = undefined;
    var builder = ExtensionBuilder.init(&buf);

    const modes = [_]PskKeyExchangeMode{.psk_dhe_ke};
    try builder.addPskKeyExchangeModes(&modes);

    const data = builder.getData();
    try std.testing.expect(data.len > 0);

    const ext_type = std.mem.readInt(u16, data[0..2], .big);
    try std.testing.expectEqual(@as(u16, @intFromEnum(ExtensionType.psk_key_exchange_modes)), ext_type);
}
